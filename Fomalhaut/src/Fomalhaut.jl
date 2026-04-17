module Fomalhaut

using Libdl
include("AsciiArt.jl")

export App, Request, WebSocketContext, serve, stop_server!, @post, @websocket
export CONTENT_TYPE_FLOAT32_TENSOR, CONTENT_TYPE_JSON, CONTENT_TYPE_RGBA_FRAME

const _rust_lib_path = Ref{Union{Nothing, String}}(nothing)
const _ffi_ok = Cint(0)
const _server_running = Ref(false)
const _active_app = Ref{Any}(nothing)
const _active_app_id = Ref(0)

const ENVELOPE_V1 = UInt8(1)
const CONTENT_TYPE_FLOAT32_TENSOR = UInt16(1)
const CONTENT_TYPE_JSON = UInt16(2)
const CONTENT_TYPE_RGBA_FRAME = UInt16(3)
const ENVELOPE_HEADER_LEN = 17

struct Request
    method::String
    path::String
    headers::Dict{String, String}
    query::String
    body::Vector{UInt8}
end

struct WebSocketContext
    path::String
    time::Float64
    frame::Int
end

mutable struct App
    http_routes::Dict{String, Function}
    ws_routes::Dict{String, Function}
    handler_refs::Vector{Any}
    ws_tasks::Vector{Task}
    id::Int
end

function App()
    _active_app_id[] += 1
    return App(Dict{String, Function}(), Dict{String, Function}(), Any[], Task[], _active_app_id[])
end

Base.show(io::IO, app::App) = print(io, "Fomalhaut.App(http=$(length(app.http_routes)), ws=$(length(app.ws_routes)))")

struct FFIHttpResponse
    status_code::UInt16
    body_ptr::Ptr{UInt8}
    body_len::Csize_t
    content_type_ptr::Ptr{UInt8}
    content_type_len::Csize_t
end

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
    elseif code == 8
        return "invalid route"
    elseif code == 9
        return "callback failed"
    else
        return "unknown error"
    end
end

function _check_ffi_status(status::Integer, context::AbstractString)
    status == _ffi_ok && return
    msg = _ffi_error_message(status)
    error("$(context) failed with status $(status): $(msg)")
end

function _validate_path(path::AbstractString)
    startswith(path, "/") || error("path must start with '/'")
    occursin("*", path) && error("wildcard routes are not supported in v0.2")
    return path
end

function register_post!(app::App, path::AbstractString, handler::Function)
    app.http_routes[String(_validate_path(path))] = handler
    return app
end

function register_websocket!(app::App, path::AbstractString, handler::Function)
    app.ws_routes[String(_validate_path(path))] = handler
    return app
end

macro post(app, path, f)
    return esc(quote
        Fomalhaut.register_post!($app, $path, $f)
    end)
end

macro websocket(app, path, f)
    return esc(quote
        Fomalhaut.register_websocket!($app, $path, $f)
    end)
end

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

function _parse_headers(headers_raw::String)
    headers = Dict{String, String}()
    isempty(headers_raw) && return headers

    for line in split(headers_raw, "\r\n"; keepempty=false)
        parts = split(line, ":"; limit=2)
        length(parts) == 2 || continue
        headers[strip(parts[1])] = strip(parts[2])
    end

    return headers
end

function _malloc_copy(bytes::Vector{UInt8})
    if isempty(bytes)
        return Ptr{UInt8}(C_NULL), Csize_t(0)
    end

    ptr = Base.Libc.malloc(length(bytes))
    ptr == C_NULL && error("malloc failed for response buffer")
    unsafe_copyto!(Ptr{UInt8}(ptr), pointer(bytes), length(bytes))
    return Ptr{UInt8}(ptr), Csize_t(length(bytes))
end

function _active_app_or_throw()
    app = _active_app[]
    app isa App || error("No active Fomalhaut app registered")
    return app::App
end

function _http_request_trampoline(
    userdata::Ptr{Cvoid},
    method_ptr::Ptr{UInt8},
    method_len::Csize_t,
    path_ptr::Ptr{UInt8},
    path_len::Csize_t,
    query_ptr::Ptr{UInt8},
    query_len::Csize_t,
    headers_ptr::Ptr{UInt8},
    headers_len::Csize_t,
    body_ptr::Ptr{UInt8},
    body_len::Csize_t,
    response_out::Ptr{FFIHttpResponse},
)::Cint
    try
        app = _active_app_or_throw()
        method = String(copy(unsafe_wrap(Vector{UInt8}, method_ptr, Int(method_len))))
        path = String(copy(unsafe_wrap(Vector{UInt8}, path_ptr, Int(path_len))))
        query = String(copy(unsafe_wrap(Vector{UInt8}, query_ptr, Int(query_len))))
        headers_raw = String(copy(unsafe_wrap(Vector{UInt8}, headers_ptr, Int(headers_len))))
        body = copy(unsafe_wrap(Vector{UInt8}, body_ptr, Int(body_len)))

        handler = get(app.http_routes, path, nothing)
        handler isa Function || return Cint(9)

        request = Request(method, path, _parse_headers(headers_raw), query, body)
        response = handler(request)
        response isa Tuple && length(response) == 2 || error("POST handler must return (Vector{UInt8}, content_type::String)")

        response_body = response[1]
        response_body isa Vector{UInt8} || error("POST handler response body must be Vector{UInt8}")
        content_type = String(response[2])

        body_ptr_out, body_len_out = _malloc_copy(response_body)
        ct_bytes = Vector{UInt8}(codeunits(content_type))
        ct_ptr_out, ct_len_out = _malloc_copy(ct_bytes)

        unsafe_store!(
            response_out,
            FFIHttpResponse(UInt16(200), body_ptr_out, body_len_out, ct_ptr_out, ct_len_out),
        )
        return Cint(0)
    catch err
        @error "Fomalhaut HTTP handler failed" exception=(err, catch_backtrace())
        return Cint(9)
    end
end

const _http_callback_ptr = @cfunction(
    _http_request_trampoline,
    Cint,
    (
        Ptr{Cvoid},
        Ptr{UInt8},
        Csize_t,
        Ptr{UInt8},
        Csize_t,
        Ptr{UInt8},
        Csize_t,
        Ptr{UInt8},
        Csize_t,
        Ptr{UInt8},
        Csize_t,
        Ptr{FFIHttpResponse},
    ),
)

function _register_routes!(app::App)
    for path in keys(app.http_routes)
        path_bytes = Vector{UInt8}(codeunits(path))
        status = ccall(
            (:fmh_register_post, _load_rust_lib()),
            Cint,
            (Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}),
            path_bytes,
            length(path_bytes),
            _http_callback_ptr,
            C_NULL,
        )
        _check_ffi_status(status, "register_post $path")
    end

    for path in keys(app.ws_routes)
        path_bytes = Vector{UInt8}(codeunits(path))
        status = ccall(
            (:fmh_register_websocket, _load_rust_lib()),
            Cint,
            (Ptr{UInt8}, Csize_t),
            path_bytes,
            length(path_bytes),
        )
        _check_ffi_status(status, "register_websocket $path")
    end
end

function broadcast_frame!(
    path::AbstractString,
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
    path_bytes = Vector{UInt8}(codeunits(path))
    status = ccall(
        (:fmh_ws_broadcast, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        path_bytes,
        length(path_bytes),
        frame,
        length(frame),
    )
    _check_ffi_status(status, "broadcast_frame! $path")
    return nothing
end

function _send_ws_data(path::String, data)
    if data isa Array{Float32}
        payload = reinterpret(UInt8, data) |> collect
        return broadcast_frame!(path, payload; content_type = CONTENT_TYPE_FLOAT32_TENSOR)
    elseif data isa Array{UInt8}
        return broadcast_frame!(path, data; content_type = CONTENT_TYPE_RGBA_FRAME)
    else
        error("Unsupported websocket data type: $(typeof(data))")
    end
end

function _start_ws_tasks!(app::App; fps::Real)
    fps > 0 || error("fps must be > 0")
    empty!(app.ws_tasks)

    for (path, handler) in app.ws_routes
        task = @async begin
            interval = 1 / fps
            start_time = time()
            frame_index = 0

            while _server_running[] && _active_app[] === app
                frame_start = time()
                try
                    ctx = WebSocketContext(path, frame_start - start_time, frame_index)
                    data = handler(ctx)
                    _send_ws_data(path, data)
                catch err
                    @error "Fomalhaut websocket handler failed" path exception=(err, catch_backtrace())
                    break
                end

                frame_index += 1
                elapsed = time() - frame_start
                sleep(max(0.0, interval - elapsed))
            end
        end
        push!(app.ws_tasks, task)
    end

    return nothing
end

function _stop_ws_tasks!(app::App)
    for task in app.ws_tasks
        istaskdone(task) || wait(task)
    end
    empty!(app.ws_tasks)
    return nothing
end

function serve(app::App; host::AbstractString = "127.0.0.1", port::Integer = 8080, fps::Real = 30)
    1 <= port <= 65535 || error("port must be in 1:65535")
    (isempty(app.http_routes) && isempty(app.ws_routes)) && error("No routes registered on this App.")
    !_server_running[] || error("A Fomalhaut server is already running")

    addr = "$(host):$(port)"
    addr_bytes = Vector{UInt8}(codeunits(addr))
    _active_app[] = app
    push!(app.handler_refs, _http_callback_ptr)
    _register_routes!(app)

    status = ccall(
        (:fmh_server_start, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t),
        addr_bytes,
        length(addr_bytes),
    )
    _check_ffi_status(status, "serve")
    _server_running[] = true
    _start_ws_tasks!(app; fps = fps)

    try
        while _server_running[]
            sleep(0.1)
        end
    finally
        if _server_running[]
            stop_server!()
        end
    end

    return nothing
end

function stop_server!()
    app = _active_app[]
    _server_running[] = false

    status = ccall((:fmh_server_stop, _load_rust_lib()), Cint, ())
    if status != 5
        _check_ffi_status(status, "stop_server!")
    end

    if app isa App
        _stop_ws_tasks!(app)
    end

    _active_app[] = nothing
    return nothing
end

function __init__()
    try
        AsciiArt.print_fomalhaut_ascii_art()
    catch err
        @warn "Failed to show Fomalhaut ASCII art." exception = (err, catch_backtrace())
    end
end

end # module Fomalhaut
