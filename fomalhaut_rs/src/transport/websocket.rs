use futures_util::SinkExt;
use tokio::net::TcpStream;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::runtime::state::state;

pub fn route_exists(path: &str) -> bool {
    match state().lock() {
        Ok(guard) => guard.ws_routes.contains_key(path),
        Err(_) => false,
    }
}

pub async fn handle_socket(path: String, stream: TcpStream) {
    let Ok(mut socket) = accept_async(stream).await else {
        return;
    };

    let tx = {
        let guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        match guard.ws_routes.get(&path) {
            Some(tx) => tx.clone(),
            None => return,
        }
    };

    let mut rx = tx.subscribe();
    while let Ok(frame) = rx.recv().await {
        if socket
            .send(Message::Binary((*frame).clone().into()))
            .await
            .is_err()
        {
            break;
        }
    }
}
