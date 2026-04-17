use std::sync::Arc;

use tokio::sync::oneshot;

use super::errors::{
    FFI_ERR_ALREADY_RUNNING, FFI_ERR_INVALID_FRAME, FFI_ERR_INVALID_ROUTE, FFI_ERR_INVALID_UTF8,
    FFI_ERR_NOT_RUNNING, FFI_ERR_NULL_PTR, FFI_ERR_PANIC, FFI_ERR_RUNTIME, FFI_OK,
};
use crate::protocol::envelope::validate_envelope;
use crate::runtime::state::state;
use crate::transport;

#[unsafe(no_mangle)]
pub extern "C" fn fmh_server_start(addr_ptr: *const u8, addr_len: usize) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if addr_ptr.is_null() {
            return FFI_ERR_NULL_PTR;
        }

        let addr_bytes = unsafe { std::slice::from_raw_parts(addr_ptr, addr_len) };
        let addr = match std::str::from_utf8(addr_bytes) {
            Ok(v) => v.to_string(),
            Err(_) => return FFI_ERR_INVALID_UTF8,
        };

        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };

        if guard.worker.is_some() {
            return FFI_ERR_ALREADY_RUNNING;
        }

        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let worker_addr = addr.clone();

        let worker = std::thread::spawn(move || {
            let threads = std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(2)
                .max(2);

            let rt = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(threads)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(err) => {
                    eprintln!("Failed to build tokio runtime: {}", err);
                    return;
                }
            };

            rt.block_on(async move {
                transport::http_server::run_until_shutdown(&worker_addr, shutdown_rx).await;
            });
        });

        guard.shutdown_tx = Some(shutdown_tx);
        guard.worker = Some(worker);
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_server_stop() -> i32 {
    let result = std::panic::catch_unwind(|| {
        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };

        if guard.worker.is_none() {
            return FFI_ERR_NOT_RUNNING;
        }

        if let Some(tx) = guard.shutdown_tx.take() {
            let _ = tx.send(());
        }

        if let Some(worker) = guard.worker.take() {
            let _ = worker.join();
        }

        guard.http_routes.clear();
        guard.ws_routes.clear();

        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_ws_broadcast(
    path_ptr: *const u8,
    path_len: usize,
    frame_ptr: *const u8,
    frame_len: usize,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if path_ptr.is_null() || frame_ptr.is_null() {
            return FFI_ERR_NULL_PTR;
        }

        let path_bytes = unsafe { std::slice::from_raw_parts(path_ptr, path_len) };
        let path = match std::str::from_utf8(path_bytes) {
            Ok(v) => v,
            Err(_) => return FFI_ERR_INVALID_UTF8,
        };

        if !path.starts_with('/') {
            return FFI_ERR_INVALID_ROUTE;
        }

        let frame = unsafe { std::slice::from_raw_parts(frame_ptr, frame_len) };
        if !validate_envelope(frame) {
            return FFI_ERR_INVALID_FRAME;
        }

        let tx = {
            let guard = match state().lock() {
                Ok(g) => g,
                Err(_) => return FFI_ERR_RUNTIME,
            };

            match guard.ws_routes.get(path) {
                Some(tx) => tx.clone(),
                None => return FFI_ERR_INVALID_ROUTE,
            }
        };

        let _ = tx.send(Arc::new(frame.to_vec()));
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}
