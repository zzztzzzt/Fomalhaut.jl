pub mod database;
pub mod ffi;
pub mod protocol;
pub mod runtime;
pub mod transport;

pub use ffi::{
    FfiHttpResponse, HttpCallback, fmh_register_http, fmh_register_post, fmh_register_websocket,
    fmh_server_start, fmh_server_stop, fmh_ws_broadcast,
};

#[cfg(test)]
mod tests {
    use super::ffi::errors::{FFI_ERR_ALREADY_RUNNING, FFI_ERR_NOT_RUNNING, FFI_OK};
    use super::protocol::envelope::{validate_envelope, ENVELOPE_HEADER_LEN, ENVELOPE_VERSION_V1};
    use super::{fmh_register_websocket, fmh_server_start, fmh_server_stop};

    fn build_test_frame(payload: &[u8]) -> Vec<u8> {
        let mut frame = Vec::with_capacity(ENVELOPE_HEADER_LEN + payload.len());
        frame.push(ENVELOPE_VERSION_V1);
        frame.extend_from_slice(&1u16.to_le_bytes());
        frame.extend_from_slice(&0u16.to_le_bytes());
        frame.extend_from_slice(&123u64.to_le_bytes());
        frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.extend_from_slice(payload);
        frame
    }

    #[test]
    fn envelope_validation_works() {
        let frame = build_test_frame(&[1, 2, 3]);
        assert!(validate_envelope(&frame));
        assert!(!validate_envelope(&[0, 1, 2]));
    }

    #[test]
    fn lifecycle_start_stop_works() {
        let addr = b"127.0.0.1:19091";
        let ws_path = b"/stream";

        assert_eq!(fmh_server_stop(), FFI_ERR_NOT_RUNNING);
        assert_eq!(
            fmh_register_websocket(ws_path.as_ptr(), ws_path.len()),
            FFI_OK
        );
        assert_eq!(fmh_server_start(addr.as_ptr(), addr.len()), FFI_OK);
        assert_eq!(
            fmh_server_start(addr.as_ptr(), addr.len()),
            FFI_ERR_ALREADY_RUNNING
        );

        assert_eq!(fmh_server_stop(), FFI_OK);
        assert_eq!(fmh_server_stop(), FFI_ERR_NOT_RUNNING);
    }
}
