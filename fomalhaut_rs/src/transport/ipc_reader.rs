use std::error::Error;
use tokio::io::AsyncReadExt;

use crate::FrameSender;

const FRAME_SIZE: usize = 96 * 96 * 4;

#[cfg(windows)]
const IPC_PATH: &str = r"\\.\pipe\phillips_ocean";
#[cfg(not(windows))]
const IPC_PATH: &str = "/tmp/phillips_ocean.sock";

#[cfg(unix)]
use tokio::net::UnixStream;
#[cfg(windows)]
use tokio::net::windows::named_pipe::ClientOptions;

pub fn spawn_frame_reader(tx: FrameSender) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            println!("Trying to connect to Julia at {}", IPC_PATH);

            let mut stream = match connect_to_julia().await {
                Ok(stream) => stream,
                Err(e) => {
                    println!("Connect failed: {}", e);
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                    continue;
                }
            };

            println!("Connected to Julia IPC!");

            let mut buffer = vec![0u8; FRAME_SIZE];
            while stream.read_exact(&mut buffer).await.is_ok() {
                let _ = tx.send(std::sync::Arc::new(buffer.clone()));
            }

            println!("Julia disconnected, retrying...");
            tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
        }
    })
}

async fn connect_to_julia(
) -> Result<Box<dyn tokio::io::AsyncRead + Unpin + Send>, Box<dyn Error + Send + Sync>> {
    #[cfg(windows)]
    {
        loop {
            match ClientOptions::new().open(IPC_PATH) {
                Ok(client) => return Ok(Box::new(client)),
                Err(e) if e.raw_os_error() == Some(231) => {
                    tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                    continue;
                }
                Err(e) => return Err(e.into()),
            }
        }
    }
    #[cfg(not(windows))]
    {
        Ok(Box::new(UnixStream::connect(IPC_PATH).await?))
    }
}
