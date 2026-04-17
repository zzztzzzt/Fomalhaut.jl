use std::ffi::c_void;

use tokio::sync::broadcast;

use super::callbacks::HttpCallback;
use super::errors::{FFI_ERR_INVALID_ROUTE, FFI_ERR_PANIC, FFI_ERR_RUNTIME, FFI_OK};
use crate::runtime::state::{HttpRoute, WsFrame, state};

fn validate_path(path: &str) -> bool {
    path.starts_with('/') && !path.contains('*')
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_register_post(
    path_ptr: *const u8,
    path_len: usize,
    callback: HttpCallback,
    userdata: *mut c_void,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if path_ptr.is_null() {
            return super::errors::FFI_ERR_NULL_PTR;
        }

        let path_bytes = unsafe { std::slice::from_raw_parts(path_ptr, path_len) };
        let path = match std::str::from_utf8(path_bytes) {
            Ok(v) if validate_path(v) => v.to_string(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };
        guard.http_routes.insert(path, HttpRoute { callback, userdata });
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_register_websocket(path_ptr: *const u8, path_len: usize) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if path_ptr.is_null() {
            return super::errors::FFI_ERR_NULL_PTR;
        }

        let path_bytes = unsafe { std::slice::from_raw_parts(path_ptr, path_len) };
        let path = match std::str::from_utf8(path_bytes) {
            Ok(v) if validate_path(v) => v.to_string(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };

        let (tx, _) = broadcast::channel::<WsFrame>(1024);
        guard.ws_routes.insert(path, tx);
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}
