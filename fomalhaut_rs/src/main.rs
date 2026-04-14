use fomalhaut_rs::{Frame, transport};
use tokio::sync::broadcast;

#[tokio::main]
async fn main() {
    let (tx, _) = broadcast::channel::<Frame>(32);

    transport::ipc_reader::spawn_frame_reader(tx.clone());
    transport::websocket_server::run("127.0.0.1:8080", tx).await;
}