use std::ffi::c_void;

use tokio::sync::broadcast;

use super::callbacks::HttpCallback;
use super::errors::{FFI_ERR_INVALID_ROUTE, FFI_ERR_PANIC, FFI_ERR_RUNTIME, FFI_OK};
use crate::runtime::state::{HttpRoute, WsFrame, state};

fn validate_path(path: &str) -> bool {
    path.starts_with('/') && !path.contains('*')
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_register_http(
    method_ptr: *const u8,
    method_len: usize,
    path_ptr: *const u8,
    path_len: usize,
    callback: HttpCallback,
    userdata: *mut c_void,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if method_ptr.is_null() || path_ptr.is_null() {
            return super::errors::FFI_ERR_NULL_PTR;
        }

        let method_bytes = unsafe { std::slice::from_raw_parts(method_ptr, method_len) };
        let method = match std::str::from_utf8(method_bytes) {
            Ok(v) if !v.is_empty() => v.to_ascii_uppercase(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        let path_bytes = unsafe { std::slice::from_raw_parts(path_ptr, path_len) };
        let mut path = match std::str::from_utf8(path_bytes) {
            Ok(v) if validate_path(v) => v.to_string(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        if path.len() > 1 && path.ends_with('/') {
            path.pop();
        }

        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };
        guard.http_routes.insert((method.clone(), path.clone()), HttpRoute { callback, userdata });
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_register_post(
    path_ptr: *const u8,
    path_len: usize,
    callback: HttpCallback,
    userdata: *mut c_void,
) -> i32 {
    fmh_register_http(
        b"POST".as_ptr(),
        4,
        path_ptr,
        path_len,
        callback,
        userdata,
    )
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

#[unsafe(no_mangle)]
pub extern "C" fn fmh_register_native_route(
    method_ptr: *const u8,
    method_len: usize,
    path_ptr: *const u8,
    path_len: usize,
    entity_ptr: *const u8,
    entity_len: usize,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if method_ptr.is_null() || path_ptr.is_null() || entity_ptr.is_null() {
            return super::errors::FFI_ERR_NULL_PTR;
        }

        let method_bytes = unsafe { std::slice::from_raw_parts(method_ptr, method_len) };
        let method = match std::str::from_utf8(method_bytes) {
            Ok(v) if !v.is_empty() => v.to_ascii_uppercase(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        let path_bytes = unsafe { std::slice::from_raw_parts(path_ptr, path_len) };
        let mut path = match std::str::from_utf8(path_bytes) {
            Ok(v) if validate_path(v) => v.to_string(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        if path.len() > 1 && path.ends_with('/') {
            path.pop();
        }

        let entity_bytes = unsafe { std::slice::from_raw_parts(entity_ptr, entity_len) };
        let entity = match std::str::from_utf8(entity_bytes) {
            Ok(v) => v.to_string(),
            _ => return FFI_ERR_INVALID_ROUTE,
        };

        let mut guard = match state().lock() {
            Ok(g) => g,
            Err(_) => return FFI_ERR_RUNTIME,
        };
        guard.native_routes.insert((method.clone(), path.clone()), entity);
        FFI_OK
    });

    match result {
        Ok(code) => code,
        Err(_) => FFI_ERR_PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_malloc(size: usize) -> *mut u8 {
    unsafe { libc::malloc(size) as *mut u8 }
}

#[unsafe(no_mangle)]
pub extern "C" fn fmh_free(ptr: *mut u8) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr.cast()) };
    }
}
