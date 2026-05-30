use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock, Mutex};

use tokio::sync::{oneshot, watch, mpsc};

use crate::ffi::callbacks::HttpCallback;
use crate::ffi::callbacks::HttpTask;

pub type WsFrame = Arc<Vec<u8>>;
pub type WsSender = watch::Sender<WsFrame>;

#[derive(Clone, Copy)]
pub struct HttpRoute {
    pub callback: HttpCallback,
    pub userdata: *mut std::ffi::c_void,
}

unsafe impl Send for HttpRoute {}
unsafe impl Sync for HttpRoute {}

pub struct ServerState {
    pub http_routes: HashMap<(String, String), HttpRoute>,
    pub ws_routes: HashMap<String, WsSender>,
    pub native_routes: HashMap<(String, String), String>,
    pub db: Option<sea_orm::DatabaseConnection>,
    pub shutdown_tx: Option<oneshot::Sender<()>>,
    pub allowed_origins: Vec<String>,
    pub http_task_tx: Option<mpsc::Sender<HttpTask>>,
}

impl ServerState {
    pub fn stopped() -> Self {
        Self {
            http_routes: HashMap::new(),
            ws_routes: HashMap::new(),
            native_routes: HashMap::new(),
            db: None,
            shutdown_tx: None,
            allowed_origins: Vec::new(),
            http_task_tx: None,
        }
    }
}

static SERVER_STATE: OnceLock<RwLock<ServerState>> = OnceLock::new();

pub fn state() -> &'static RwLock<ServerState> {
    SERVER_STATE.get_or_init(|| RwLock::new(ServerState::stopped()))
}

static HTTP_TASK_RX: OnceLock<Mutex<mpsc::Receiver<HttpTask>>> = OnceLock::new();

pub fn set_http_task_rx(rx: mpsc::Receiver<HttpTask>) {
    // If there are already old ones, clear them first ( server restart scenario )
    // OnceLock itself cannot be reset, so the value in the Mutex is used to replace it
    if let Some(lock) = HTTP_TASK_RX.get() {
        if let Ok(mut guard) = lock.lock() {
            *guard = rx;
        }
    } else {
        let _ = HTTP_TASK_RX.set(Mutex::new(rx));
    }
}

pub fn try_recv_http_task() -> Option<HttpTask> {
    let lock = HTTP_TASK_RX.get()?;
    let mut guard = lock.lock().ok()?;
    guard.try_recv().ok()
}
