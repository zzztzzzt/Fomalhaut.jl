import Fomalhaut as FMHUT

import Axis as AX

const RES = 96
const R = Float32[-3f0 + 6f0 * (i-1) / (RES-1) for i in 1:RES]

const OUT_BUFFER = Vector{Float32}(undef, RES * RES)

mutable struct WaveContext
    start_time_sec::Float64
    r::Ptr{Float32}
    res::Int32
    out::Ptr{Float32}
end

@AX.rust_code """
#[repr(C)]
pub struct WaveContext {
    pub start_time_sec: f64,
    pub r: *const f32,
    pub res: i32,
    pub out: *mut f32,
}
"""

@AX.rust_fn function _wave_native_frame(ctx::Ptr{Cvoid}, out_len::Ptr{Csize_t})::Ptr{UInt8}
    """
    let ctx = unsafe { &mut *(ctx as *mut WaveContext) };

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    if ctx.start_time_sec == 0.0 {
        ctx.start_time_sec = now;
    }
    let t = ((now - ctx.start_time_sec) * 2.0) as f32;

    let res = ctx.res as usize;
    let r = unsafe { std::slice::from_raw_parts(ctx.r, res) };
    let out = unsafe { std::slice::from_raw_parts_mut(ctx.out, res * res) };

    for i in 0..res {
        for j in 0..res {
            out[i * res + j] = (r[i] + t).sin() + (r[j] + t).cos();
        }
    }

    unsafe {
        *out_len = (res * res * 4) as usize;
        ctx.out as *mut u8
    }
    """
end

const _WAVE_CTX = Ref{WaveContext}()

function init!()
    _WAVE_CTX[] = WaveContext(0.0, pointer(R), Int32(RES), pointer(OUT_BUFFER))
end

function get_native_generator()
    ctx_ptr = Base.unsafe_convert(Ptr{Cvoid}, _WAVE_CTX)
    cb_ptr = AX._axis_rs_symbol(Symbol("_wave_native_frame"))
    return cb_ptr, ctx_ptr
end

init!()

axis_generated_dir = abspath(joinpath(@__DIR__, "..", "axis_rs"))
@info "Triggering Axis Rust code generator..." axis_generated_dir
AX.bridge_up(axis_generated_dir)

cb_ptr, ctx_ptr = get_native_generator()

app = FMHUT.App()

@FMHUT.axis_websocket app "/live-wave" 60.0 cb_ptr ctx_ptr

FMHUT.serve(app; port=8080, fps=60)

#=
Frontend Usage Example :

const ws = new WebSocket("ws://127.0.0.1:8080/live-wave");
ws.binaryType = "arraybuffer";

ws.onopen = () => {
  console.log("WebSocket connected");
};

ws.onmessage = (event) => {
  const frame = new Uint8Array(event.data);

  console.log("Frame Bytes :", frame.byteLength);

  const version = frame[0];
  const contentType = new DataView(frame.buffer).getUint16(1, true);
  const payloadLength = new DataView(frame.buffer).getUint32(13, true);
  const payload = frame.slice(17, 17 + payloadLength);
  const tensor = new Float32Array(
    payload.buffer,
    payload.byteOffset,
    payload.byteLength / 4
  );

  console.log("Envelope Version :", version);
  console.log("Content Type ( Expected 1 ) :", contentType);
  console.log("Float32 Count ( Expected 9216 ) :", tensor.length);
  console.log("First 8 Values :", Array.from(tensor.slice(0, 8)));
};

ws.onerror = (err) => {
  console.error("WebSocket error :", err);
};

ws.onclose = () => {
  console.log("WebSocket closed");
};
=#