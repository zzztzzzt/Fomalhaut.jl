use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock, RwLock, Mutex};

use tokio::sync::{oneshot, watch, mpsc};

use crate::ffi::callbacks::HttpCallback;
use crate::ffi::callbacks::HttpTask;

/// C function pointer type for waking up Julia's AsyncCondition
pub type HttpNotifierCb = unsafe extern "C" fn(*mut std::ffi::c_void);

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

// Notifier : fast path without holding RwLock
// Store the callback and handle as atomics so invoke_via_channel can fire
// the notifier cheaply without acquiring the state RwLock.
static HTTP_NOTIFIER_CB: AtomicUsize = AtomicUsize::new(0);
static HTTP_NOTIFIER_HANDLE: AtomicUsize = AtomicUsize::new(0);

pub fn set_http_notifier(cb: HttpNotifierCb, handle: *mut std::ffi::c_void) {
    HTTP_NOTIFIER_CB.store(cb as usize, Ordering::Release);
    HTTP_NOTIFIER_HANDLE.store(handle as usize, Ordering::Release);
}

pub fn clear_http_notifier() {
    HTTP_NOTIFIER_CB.store(0, Ordering::Release);
    HTTP_NOTIFIER_HANDLE.store(0, Ordering::Release);
}

/// Trigger the Julia AsyncCondition notifier if one has been registered.
/// Safe to call from any thread; does nothing if notifier is not set.
pub fn notify_julia() {
    let cb_ptr = HTTP_NOTIFIER_CB.load(Ordering::SeqCst);
    let handle_ptr = HTTP_NOTIFIER_HANDLE.load(Ordering::SeqCst);

    if cb_ptr != 0 && handle_ptr != 0 {
        let cb: HttpNotifierCb = unsafe { std::mem::transmute(cb_ptr as *const ()) };
        unsafe { cb(handle_ptr as *mut std::ffi::c_void) };
    }
}
