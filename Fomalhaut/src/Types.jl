const ENVELOPE_V1 = UInt8(1)
const CONTENT_TYPE_FLOAT32_TENSOR = UInt16(1)
const CONTENT_TYPE_JSON = UInt16(2)
const CONTENT_TYPE_RGBA_FRAME = UInt16(3)
const ENVELOPE_HEADER_LEN = 17

const _rust_lib_path = Ref{Union{Nothing, String}}(nothing)
const _ffi_ok = Cint(0)
const _server_running = Ref(false)
const _active_app = Ref{Any}(nothing)
const _active_app_id = Ref(0)
const _http_callback_ptr = Ref{Ptr{Cvoid}}(C_NULL)

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
    http_routes::Dict{Tuple{String, String}, Function}
    ws_routes::Dict{String, Function}
    native_routes::Dict{Tuple{String, String}, String}
    handler_refs::Vector{Any}
    ws_tasks::Vector{Task}
    id::Int
end

function App()
    _active_app_id[] += 1
    return App(
        Dict{Tuple{String, String}, Function}(), 
        Dict{String, Function}(), 
        Dict{Tuple{String, String}, String}(),
        Any[], 
        Task[], 
        _active_app_id[]
    )
end

Base.show(io::IO, app::App) = print(io, "Fomalhaut.App(http=$(length(app.http_routes)), ws=$(length(app.ws_routes)))")

struct FFIHttpResponse
    body_ptr::Ptr{UInt8}
    body_len::Csize_t
    content_type_ptr::Ptr{UInt8}
    content_type_len::Csize_t
    status_code::UInt16
end
