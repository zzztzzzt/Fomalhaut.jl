// Offset constants
pub const ENVELOPE_HEADER_LEN: usize = 17;
pub const ENVELOPE_VERSION_V1: u8 = 1;

const VERSION_OFFSET: usize = 0;
const CONTENT_TYPE_OFFSET: usize = 1;
const FLAGS_OFFSET: usize = 3;
const TIMESTAMP_NS_OFFSET: usize = 5;
const PAYLOAD_LEN_OFFSET: usize = 13;

// Header struct
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeHeader {
    pub version: u8,
    pub content_type: u16,
    pub flags: u16,
    pub timestamp_ns: u64,
    pub payload_len: u32,
}

impl EnvelopeHeader {
    /// Parse the header from raw bytes; return None if the length is insufficient
    pub fn parse(frame: &[u8]) -> Option<Self> {
        if frame.len() < ENVELOPE_HEADER_LEN {
            return None;
        }
        Some(Self {
            version: frame[VERSION_OFFSET],
            content_type: u16::from_le_bytes(
                frame[CONTENT_TYPE_OFFSET..FLAGS_OFFSET].try_into().ok()?,
            ),
            flags: u16::from_le_bytes(
                frame[FLAGS_OFFSET..TIMESTAMP_NS_OFFSET].try_into().ok()?,
            ),
            timestamp_ns: u64::from_le_bytes(
                frame[TIMESTAMP_NS_OFFSET..PAYLOAD_LEN_OFFSET].try_into().ok()?,
            ),
            payload_len: u32::from_le_bytes(
                frame[PAYLOAD_LEN_OFFSET..ENVELOPE_HEADER_LEN].try_into().ok()?,
            ),
        })
    }

    /// Check if the header itself is valid ( whether the version number and payload length match the actual frame )
    pub fn is_valid(&self, total_frame_len: usize) -> bool {
        self.version == ENVELOPE_VERSION_V1
            && self.payload_len as usize == total_frame_len - ENVELOPE_HEADER_LEN
    }
}

// Public API
pub fn validate_envelope(frame: &[u8]) -> bool {
    EnvelopeHeader::parse(frame)
        .map(|h| h.is_valid(frame.len()))
        .unwrap_or(false)
}