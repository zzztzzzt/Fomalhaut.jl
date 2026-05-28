use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::{oneshot, watch};

use crate::ffi::callbacks::HttpCallback;

pub type WsFrame = Arc<Vec<u8>>;
pub type WsSender = watch::Sender<WsFrame>;

#[derive(Clone, Copy)]
pub struct HttpRoute {
    pub callback: HttpCallback,
    pub userdata: *mut c_void,
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
        }
    }
}

static SERVER_STATE: OnceLock<Mutex<ServerState>> = OnceLock::new();

pub fn state() -> &'static Mutex<ServerState> {
    SERVER_STATE.get_or_init(|| Mutex::new(ServerState::stopped()))
}
