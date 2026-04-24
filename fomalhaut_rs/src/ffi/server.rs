use std::sync::Arc;

use tokio::sync::oneshot;

use super::errors::{
    FFI_ERR_ALREADY_RUNNING, FFI_ERR_INVALID_FRAME, FFI_ERR_INVALID_ROUTE, FFI_ERR_INVALID_UTF8,
    FFI_ERR_NULL_PTR, FFI_ERR_PANIC, FFI_ERR_RUNTIME, FFI_OK,
};
use crate::protocol::envelope::validate_envelope;
use crate::runtime::state::state;
use crate::transport;

#[unsafe(no_mangle)]
pub extern "C" fn fmh_db_connect(url_ptr: *const u8, url_len: usize) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if url_ptr.is_null() {
            return FFI_ERR_NULL_PTR;
        }

        let url_bytes = unsafe { std::slice::from_raw_parts(url_ptr, url_len) };
        let url = match std::str::from_utf8(url_bytes) {
            Ok(v) => v.to_string(),
            Err(_) => return FFI_ERR_INVALID_UTF8,
        };

        let (tx, rx) = std::sync::mpsc::channel::<Result<sea_orm::DatabaseConnection, sea_orm::DbErr>>();

        let url_for_log = url.clone();

        std::thread::spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(_) => {
                    return;
                }
            };

            rt.block_on(async move {
                let conn = crate::database::connect(&url).await;
                let _ = tx.send(conn);
            });
        });

        match rx.recv() {
            Ok(Ok(conn)) => {
                let mut guard = match state().lock() {
                    Ok(g) => g,
                    Err(_) => return FFI_ERR_RUNTIME,
                };
                guard.db = Some(conn);
                println!("Connected to database: {}", url_for_log);
                FFI_OK
            }
            Ok(Err(err)) => {
                eprintln!("Database connection error: {}", err);
                FFI_ERR_RUNTIME
            }
            Err(_) => FFI_ERR_RUNTIME,
        }
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

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

        if guard.shutdown_tx.is_some() {
            return FFI_ERR_ALREADY_RUNNING;
        }

        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let worker_addr = addr.clone();

        guard.shutdown_tx = Some(shutdown_tx);
        drop(guard); // Release lock before spawning thread

        // Use a channel to wait for the listener to bind before returning FFI_OK
        let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();

        std::thread::spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(err) => {
                    let _ = tx.send(Err(format!("Failed to build tokio runtime: {}", err)));
                    return;
                }
            };

            rt.block_on(async move {
                let listener = match tokio::net::TcpListener::bind(&worker_addr).await {
                    Ok(l) => {
                        let _ = tx.send(Ok(()));
                        l
                    }
                    Err(err) => {
                        let _ = tx.send(Err(format!("Failed to bind to {}: {}", worker_addr, err)));
                        return;
                    }
                };

                transport::http_server::run_with_listener(listener, shutdown_rx).await;
            });
        });

        // Wait for bind success or failure (short timeout if needed, but recv is fine)
        match rx.recv() {
            Ok(Ok(_)) => {
                println!("Started server process on http://{}", addr);

                FFI_OK
            },
            Ok(Err(err)) => {
                eprintln!("Server start error: {}", err);
                // Clear shutdown_tx if bind failed
                if let Ok(mut g) = state().lock() {
                    g.shutdown_tx = None;
                }
                FFI_ERR_RUNTIME
            }
            Err(_) => FFI_ERR_RUNTIME,
        }
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

        if let Some(tx) = guard.shutdown_tx.take() {
            let _ = tx.send(());
        } else {
            println!("No shutdown_tx found ( server not running? )");
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
                None => {
                    return FFI_ERR_INVALID_ROUTE;
                }
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
