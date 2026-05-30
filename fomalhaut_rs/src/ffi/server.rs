use std::sync::Arc;

use tokio::sync::oneshot;

use super::errors::{
    FFI_ERR_ALREADY_RUNNING, FFI_ERR_INVALID_FRAME, FFI_ERR_INVALID_ROUTE, FFI_ERR_INVALID_UTF8,
    FFI_ERR_NULL_PTR, FFI_ERR_PANIC, FFI_ERR_RUNTIME, FFI_OK, FFI_ERR_NOT_READY, FFI_OK_WITH_TASK,
};
use crate::protocol::envelope::validate_envelope;
use crate::runtime::state::state;
use crate::transport;
use crate::ffi::callbacks::CallbackResponse;

#[unsafe(no_mangle)]
pub extern "C" fn fmh_set_allowed_origins(origins_ptr: *const u8, origins_len: usize) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if origins_ptr.is_null() && origins_len != 0 {
            return FFI_ERR_NULL_PTR;
        }

        let origins_bytes = if origins_len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(origins_ptr, origins_len) }
        };
        let origins_raw = match std::str::from_utf8(origins_bytes) {
            Ok(v) => v,
            Err(_) => return FFI_ERR_INVALID_UTF8,
        };

        let origins = origins_raw
            .lines()
            .map(str::trim)
            .filter(|origin| !origin.is_empty())
            .map(str::to_string)
            .collect();

        let mut guard = match state().write() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };
        guard.allowed_origins = origins;
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

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
                let mut guard = match state().write() {
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

        let mut guard = match state().write() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };

        if guard.shutdown_tx.is_some() {
            return FFI_ERR_ALREADY_RUNNING;
        }

        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let (http_task_tx, http_task_rx) = tokio::sync::mpsc::channel::<crate::ffi::callbacks::HttpTask>(64);
        crate::runtime::state::set_http_task_rx(http_task_rx);
        let worker_addr = addr.clone();

        guard.shutdown_tx = Some(shutdown_tx);
        guard.http_task_tx = Some(http_task_tx);
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

        // Wait for bind success or failure ( short timeout if needed, but recv is fine )
        match rx.recv() {
            Ok(Ok(_)) => {
                println!("☄️ ||||||  Started server process on http://{}  |||||| ☄️", addr);

                FFI_OK
            },
            Ok(Err(err)) => {
                eprintln!("Server start error: {}", err);
                // Clear shutdown_tx if bind failed
                if let Ok(mut g) = state().write() {
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
        let mut guard = match state().write() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };

        if let Some(tx) = guard.shutdown_tx.take() {
            let _ = tx.send(());
        } else {
            println!("No shutdown_tx found ( server not running? )");
        }

        guard.http_task_tx = None;
        guard.http_routes.clear();
        guard.ws_routes.clear();
        guard.allowed_origins.clear();

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

        {
            let guard = match state().read() {
                Ok(g) => g,
                Err(_) => return FFI_ERR_RUNTIME,
            };

            match guard.ws_routes.get(path) {
                Some(tx) => {
                    let _ = tx.send(Arc::new(frame.to_vec()));
                }
                None => {
                    return FFI_ERR_INVALID_ROUTE;
                }
            }
        }
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_poll_http_task(
    data_out: *mut crate::ffi::callbacks::FfiHttpTaskData,
) -> i32 {
    if data_out.is_null() {
        return FFI_ERR_NULL_PTR;
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match crate::runtime::state::try_recv_http_task() {
            None => FFI_ERR_NOT_READY,
            Some(task) => {
                let handle = Box::new(crate::ffi::callbacks::FfiHttpTaskHandle {
                    method: task.method,
                    path: task.path,
                    query: task.query,
                    headers: task.headers,
                    body: task.body,
                    route: task.route,
                    response_tx: task.response_tx,
                });

                unsafe {
                    (*data_out).method_ptr = handle.method.as_ptr();
                    (*data_out).method_len = handle.method.len();
                    (*data_out).path_ptr = handle.path.as_ptr();
                    (*data_out).path_len = handle.path.len();
                    (*data_out).query_ptr = handle.query.as_ptr();
                    (*data_out).query_len = handle.query.len();
                    (*data_out).headers_ptr = handle.headers.as_ptr();
                    (*data_out).headers_len = handle.headers.len();
                    (*data_out).body_ptr = handle.body.as_ptr();
                    (*data_out).body_len = handle.body.len();
                    (*data_out).task_handle = Box::into_raw(handle);
                }

                FFI_OK_WITH_TASK
            }
        }
    }));

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_complete_http_task(
    task_ptr: *mut crate::ffi::callbacks::FfiHttpTaskHandle,
    status_code: u16,
    body_ptr: *mut u8,
    body_len: usize,
    content_type_ptr: *mut u8,
    content_type_len: usize,
) -> i32 {
    if task_ptr.is_null() {
        return FFI_ERR_NULL_PTR;
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Reclaim ownership; automatically drop when leaving scope
        let handle = unsafe { Box::from_raw(task_ptr) };

        let body = if body_len == 0 || body_ptr.is_null() {
            Vec::new()
        } else {
            let bytes = unsafe { std::slice::from_raw_parts(body_ptr, body_len).to_vec() };
            unsafe { libc::free(body_ptr.cast()) };
            bytes
        };

        let content_type = if content_type_len == 0 || content_type_ptr.is_null() {
            "text/plain".to_string()
        } else {
            let bytes = unsafe { std::slice::from_raw_parts(content_type_ptr, content_type_len).to_vec() };
            unsafe { libc::free(content_type_ptr.cast()) };
            String::from_utf8(bytes).unwrap_or_else(|_| "text/plain".to_string())
        };

        let response = Ok(CallbackResponse {
            status_code: if status_code == 0 { 200 } else { status_code },
            body,
            content_type,
        });

        let _ = handle.response_tx.send(response);
        FFI_OK
    }));

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}
