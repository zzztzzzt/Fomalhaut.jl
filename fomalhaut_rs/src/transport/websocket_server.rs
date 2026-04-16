use bytes::Bytes;
use futures_util::SinkExt;
use tokio::net::TcpStream;
use tokio::sync::oneshot;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::FrameSender;

pub async fn run(addr: &str, tx: FrameSender) {
    let (_shutdown_tx, shutdown_rx) = oneshot::channel();
    run_until_shutdown(addr, tx, shutdown_rx).await;
}

pub async fn run_until_shutdown(addr: &str, tx: FrameSender, mut shutdown_rx: oneshot::Receiver<()>) {
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind");
    println!("WebSocket Server: ws://{}", addr);

    loop {
        tokio::select! {
            _ = &mut shutdown_rx => {
                println!("WebSocket server shutdown signal received.");
                break;
            }
            incoming = listener.accept() => {
                match incoming {
                    Ok((stream, _)) => {
                        let tx = tx.clone();
                        tokio::spawn(handle_connection(stream, tx));
                    }
                    Err(err) => {
                        println!("Accept failed: {}", err);
                        break;
                    }
                }
            }
        }
    }
}

async fn handle_connection(stream: TcpStream, tx: FrameSender) {
    if let Ok(mut ws_stream) = accept_async(stream).await {
        let mut rx = tx.subscribe();
        
        loop {
            match rx.recv().await {
                // Data received normally
                Ok(frame) => {
                    let payload = Bytes::from((*frame).clone());
                    if ws_stream.send(Message::Binary(payload)).await.is_err() {
                        break; // Only exit if the transmission fails ( connection drops )
                    }
                }
                // Handling buffer overflow ( Lagged )
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    eprintln!("Client lagged by {} frames, skipping to latest.", n);
                    continue; // Skip the old frames and continue trying to receive the latest ones
                }
                // Channel is closed
                Err(_) => break,
            }
        }
    }
}
