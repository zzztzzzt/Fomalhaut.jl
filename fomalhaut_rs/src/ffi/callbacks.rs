use std::ffi::c_void;

use super::errors::{FFI_ERR_CALLBACK_FAILED, FFI_ERR_NULL_PTR};
use crate::runtime::state::HttpRoute;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct FfiHttpResponse {
    pub status_code: u16,
    pub body_ptr: *mut u8,
    pub body_len: usize,
    pub content_type_ptr: *mut u8,
    pub content_type_len: usize,
}

pub type HttpCallback = unsafe extern "C" fn(
    userdata: *mut c_void,
    method_ptr: *const u8,
    method_len: usize,
    path_ptr: *const u8,
    path_len: usize,
    query_ptr: *const u8,
    query_len: usize,
    headers_ptr: *const u8,
    headers_len: usize,
    body_ptr: *const u8,
    body_len: usize,
    response_out: *mut FfiHttpResponse,
) -> i32;

pub struct CallbackResponse {
    pub status_code: u16,
    pub body: Vec<u8>,
    pub content_type: String,
}

pub fn invoke_http_callback(
    route: HttpRoute,
    method: &[u8],
    path: &[u8],
    query: &[u8],
    headers: &[u8],
    body: &[u8],
) -> Result<CallbackResponse, i32> {
    let mut ffi_response = FfiHttpResponse::default();
    let status = unsafe {
        (route.callback)(
            route.userdata,
            method.as_ptr(),
            method.len(),
            path.as_ptr(),
            path.len(),
            query.as_ptr(),
            query.len(),
            headers.as_ptr(),
            headers.len(),
            body.as_ptr(),
            body.len(),
            &mut ffi_response as *mut FfiHttpResponse,
        )
    };

    if status != 0 {
        return Err(status);
    }

    let content_type_bytes = take_owned_bytes(ffi_response.content_type_ptr, ffi_response.content_type_len)?;
    let body_bytes = take_owned_bytes(ffi_response.body_ptr, ffi_response.body_len)?;
    let content_type = String::from_utf8(content_type_bytes).map_err(|_| FFI_ERR_CALLBACK_FAILED)?;
    let status_code = if ffi_response.status_code == 0 {
        200
    } else {
        ffi_response.status_code
    };

    Ok(CallbackResponse {
        status_code,
        body: body_bytes,
        content_type,
    })
}

fn take_owned_bytes(ptr: *mut u8, len: usize) -> Result<Vec<u8>, i32> {
    if len == 0 {
        if !ptr.is_null() {
            unsafe {
                libc::free(ptr.cast());
            }
        }
        return Ok(Vec::new());
    }

    if ptr.is_null() {
        return Err(FFI_ERR_NULL_PTR);
    }

    let bytes = unsafe { std::slice::from_raw_parts(ptr, len).to_vec() };
    unsafe {
        libc::free(ptr.cast());
    }
    Ok(bytes)
}
