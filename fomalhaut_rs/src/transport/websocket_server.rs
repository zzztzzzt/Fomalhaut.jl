use bytes::Bytes;
use futures_util::SinkExt;
use tokio::net::TcpStream;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::FrameSender;

pub async fn run(addr: &str, tx: FrameSender) {
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind");
    println!("WebSocket Server: ws://{}", addr);

    while let Ok((stream, _)) = listener.accept().await {
        let tx = tx.clone();
        tokio::spawn(handle_connection(stream, tx));
    }
}

async fn handle_connection(stream: TcpStream, tx: FrameSender) {
    if let Ok(mut ws_stream) = accept_async(stream).await {
        let mut rx = tx.subscribe();
        while let Ok(frame) = rx.recv().await {
            let payload = Bytes::from((*frame).clone());
            if ws_stream.send(Message::Binary(payload)).await.is_err() {
                break;
            }
        }
    }
}
