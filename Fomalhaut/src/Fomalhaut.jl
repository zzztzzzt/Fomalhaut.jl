module Fomalhaut

using Libdl
include("AsciiArt.jl")

export start_server, send_frame!, stop_server!
export CONTENT_TYPE_FLOAT32_TENSOR, CONTENT_TYPE_JSON, CONTENT_TYPE_RGBA_FRAME

export @stream

const _streams = []

# Cache the loaded dynamic library handle for repeated FFI calls
const _rust_lib_path = Ref{Union{Nothing, String}}(nothing)
const _ffi_ok = Cint(0)
const _server_running = Ref(false)

# Envelope v1 constants for Julia -> Rust binary framing
const ENVELOPE_V1 = UInt8(1)
const CONTENT_TYPE_FLOAT32_TENSOR = UInt16(1)
const CONTENT_TYPE_JSON = UInt16(2)
const CONTENT_TYPE_RGBA_FRAME = UInt16(3)
const ENVELOPE_HEADER_LEN = 17

function _rust_lib_filename()
    if Sys.iswindows()
        return "fomalhaut_rs.dll"
    elseif Sys.isapple()
        return "libfomalhaut_rs.dylib"
    else
        return "libfomalhaut_rs.so"
    end
end

function _rust_lib_candidates()
    file = _rust_lib_filename()
    return (
        joinpath(@__DIR__, "..", "..", "fomalhaut_rs", "target", "release", file),
        joinpath(@__DIR__, "..", "..", "fomalhaut_rs", "target", "debug", file),
    )
end

# Resolve Rust shared library path once from known build output locations
function _load_rust_lib()
    if _rust_lib_path[] !== nothing
        return _rust_lib_path[]::String
    end

    for path in _rust_lib_candidates()
        if isfile(path)
            _rust_lib_path[] = path
            return path
        end
    end

    error("Could not find Rust dynamic library. Build fomalhaut_rs first ( cargo build --release ).")
end

function _ffi_error_message(code::Integer)
    if code == 0
        return "ok"
    elseif code == 1
        return "null pointer"
    elseif code == 2
        return "panic caught in Rust"
    elseif code == 3
        return "invalid UTF-8 input"
    elseif code == 4
        return "server already running"
    elseif code == 5
        return "server not running"
    elseif code == 6
        return "runtime internal error"
    elseif code == 7
        return "invalid envelope frame"
    else
        return "unknown error"
    end
end

function _check_ffi_status(status::Integer, context::AbstractString)
    status == _ffi_ok && return
    msg = _ffi_error_message(status)
    error("$(context) failed with status $(status): $(msg)")
end

# Build envelope v1 bytes: version(u8), content_type(u16), flags(u16), timestamp_ns(u64), payload_len(u32), payload
function _build_envelope_v1(
    payload::Vector{UInt8};
    content_type::UInt16 = CONTENT_TYPE_FLOAT32_TENSOR,
    flags::UInt16 = 0x0000,
    timestamp_ns::UInt64 = UInt64(time_ns()),
)
    payload_len = length(payload)
    payload_len <= typemax(UInt32) || error("Payload too large for envelope v1.")

    frame = Vector{UInt8}(undef, ENVELOPE_HEADER_LEN + payload_len)
    frame[1] = ENVELOPE_V1
    frame[2:3] = reinterpret(UInt8, [htol(content_type)])
    frame[4:5] = reinterpret(UInt8, [htol(flags)])
    frame[6:13] = reinterpret(UInt8, [htol(timestamp_ns)])
    frame[14:17] = reinterpret(UInt8, [htol(UInt32(payload_len))])
    frame[18:end] = payload
    return frame
end

macro stream(path, f)
    return esc(quote
        push!(Fomalhaut._streams, $f)
    end)
end

"""
start_server(; host="127.0.0.1", port=8080, path="/")

Start Rust websocket transport runtime
"""
function start_server(; host::AbstractString = "127.0.0.1", port::Integer = 8080, path::AbstractString = "/")
    1 <= port <= 65535 || error("port must be in 1:65535")
    startswith(path, "/") || error("path must start with '/'")
    path == "/" || @warn "Current Rust WS runtime binds host:port only; path is reserved for future HTTP/WS routing."

    addr = "$(host):$(port)"
    addr_bytes = Vector{UInt8}(codeunits(addr))
    status = ccall(
        (:fmh_ws_start, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t),
        addr_bytes,
        length(addr_bytes),
    )
    _check_ffi_status(status, "start_server")
    _server_running[] = true
    return nothing
end

"""
send_frame!(payload::Vector{UInt8}; content_type=CONTENT_TYPE_FLOAT32_TENSOR, flags=0x0000, timestamp_ns=UInt64(time_ns()))

Build envelope v1 and send it via Rust websocket transport.
"""
function send_frame!(
    payload::Vector{UInt8};
    content_type::UInt16 = CONTENT_TYPE_FLOAT32_TENSOR,
    flags::UInt16 = 0x0000,
    timestamp_ns::UInt64 = UInt64(time_ns()),
)
    frame = _build_envelope_v1(
        payload;
        content_type = content_type,
        flags = flags,
        timestamp_ns = timestamp_ns,
    )

    status = ccall(
        (:fmh_ws_send, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t),
        frame,
        length(frame),
    )
    _check_ffi_status(status, "send_frame!")
    return nothing
end

function send(data)
    if data isa Array{Float32}
        payload = reinterpret(UInt8, data) |> collect
        return send_frame!(
            payload;
            content_type = CONTENT_TYPE_FLOAT32_TENSOR,
        )

    elseif data isa Array{UInt8}
        return send_frame!(
            data;
            content_type = CONTENT_TYPE_RGBA_FRAME,
        )

    else
        error("Unsupported data type: $(typeof(data))")
    end
end

"""
run(callback; fps=30, host="127.0.0.1", port=8080)

High-level streaming API.
User provides a callback that returns frame data.
"""
function run(callback; fps::Real=30, host="127.0.0.1", port::Integer=8080)
    fps > 0 || error("fps must be > 0")

    start_server(host=host, port=port)

    interval = 1 / fps
    start_time = time()
    frame_index = 0

    try
        while true
            frame_start = time()

            ctx = (
                time = frame_start - start_time,
                frame = frame_index,
            )

            data = callback(ctx)

            send(data)

            frame_index += 1

            elapsed = time() - frame_start
            sleep(max(0.0, interval - elapsed))
        end

    catch err
        @error "Fomalhaut.run loop error" exception=(err, catch_backtrace())
        rethrow()

    finally
        try
            stop_server!()
        catch stop_err
            @warn "Failed to stop server cleanly" exception=(stop_err, catch_backtrace())
        end
    end
end

function start(; fps=30, host="127.0.0.1", port=8080)
    length(_streams) > 0 || error("No streams registered.")

    run(fps=fps, host=host, port=port) do ctx
        _streams[1](ctx)
    end
end

"""
stop_server!()

Stop Rust websocket transport runtime.
"""
function stop_server!()
    status = ccall((:fmh_ws_stop, _load_rust_lib()), Cint, ())
    _check_ffi_status(status, "stop_server!")
    _server_running[] = false
    return nothing
end



# Called when the module is loaded; display brand ASCII art in terminal sessions
function __init__()
    try
        AsciiArt.print_fomalhaut_ascii_art()
    catch err
        # Branding output must never break package initialization
        @warn "Failed to show Fomalhaut ASCII art." exception = (err, catch_backtrace())
    end
end

end # module Fomalhaut
