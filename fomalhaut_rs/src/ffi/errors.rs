// Stable status codes across the FFI boundary
pub const FFI_OK: i32 = 0;
pub const FFI_ERR_NULL_PTR: i32 = 1;
pub const FFI_ERR_PANIC: i32 = 2;
pub const FFI_ERR_INVALID_UTF8: i32 = 3;
pub const FFI_ERR_ALREADY_RUNNING: i32 = 4;
pub const FFI_ERR_NOT_RUNNING: i32 = 5;
pub const FFI_ERR_RUNTIME: i32 = 6;
pub const FFI_ERR_INVALID_FRAME: i32 = 7;
pub const FFI_ERR_INVALID_ROUTE: i32 = 8;
pub const FFI_ERR_CALLBACK_FAILED: i32 = 9;
