use std::sync::Arc;
use tokio::sync::broadcast;

pub mod transport;

pub type Frame = Arc<Vec<u8>>;
pub type FrameSender = broadcast::Sender<Frame>;
