use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;

use tokio::sync::{broadcast, oneshot};

use crate::ffi::callbacks::HttpCallback;

pub type WsFrame = Arc<Vec<u8>>;
pub type WsSender = broadcast::Sender<WsFrame>;

#[derive(Clone, Copy)]
pub struct HttpRoute {
    pub callback: HttpCallback,
    pub userdata: *mut c_void,
}

unsafe impl Send for HttpRoute {}
unsafe impl Sync for HttpRoute {}

pub struct ServerState {
    pub http_routes: HashMap<String, HttpRoute>,
    pub ws_routes: HashMap<String, WsSender>,
    pub shutdown_tx: Option<oneshot::Sender<()>>,
    pub worker: Option<JoinHandle<()>>,
}

impl ServerState {
    pub fn stopped() -> Self {
        Self {
            http_routes: HashMap::new(),
            ws_routes: HashMap::new(),
            shutdown_tx: None,
            worker: None,
        }
    }
}

static SERVER_STATE: OnceLock<Mutex<ServerState>> = OnceLock::new();

pub fn state() -> &'static Mutex<ServerState> {
    SERVER_STATE.get_or_init(|| Mutex::new(ServerState::stopped()))
}
