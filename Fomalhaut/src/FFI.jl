# Manually Validated by zzztzzzt-SakuraAxis 2026-05-30

const _RUST_LIB_FILENAME = Sys.iswindows() ? "fomalhaut_rs.dll" :
                           Sys.isapple() ? "libfomalhaut_rs.dylib" :
                           "libfomalhaut_rs.so"
@inline _rust_lib_filename() = _RUST_LIB_FILENAME

const _RUST_LIB_CANDIDATES = let file = _rust_lib_filename()
    (
        joinpath(@__DIR__, "..", "..", "fomalhaut_rs", "target", "release", file),
        joinpath(@__DIR__, "..", "..", "fomalhaut_rs", "target", "debug", file),
    )
end
@inline _rust_lib_candidates() = _RUST_LIB_CANDIDATES

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

const _FFI_ERRORS = (
    "ok",
    "null pointer",
    "panic caught in Rust",
    "invalid UTF-8 input",
    "server already running",
    "server not running",
    "runtime internal error",
    "invalid envelope frame",
    "invalid route",
    "callback failed",
)
@inline function _ffi_error_message(code::Integer)
    i = Int(code) + 1
    return checkbounds(Bool, _FFI_ERRORS, i) ? _FFI_ERRORS[i] : "unknown error"
end

@noinline function _throw_ffi_error(status::Integer, context::AbstractString)
    msg = _ffi_error_message(status)
    error("$(context) failed with status $(status) : $(msg)")
end

@inline function _check_ffi_status(status::Integer, context::AbstractString)
    status == _ffi_ok || _throw_ffi_error(status, context)
    return nothing
end

function _parse_headers(headers_raw::String)
    headers = Dict{String, String}()

    isempty(headers_raw) && return headers

    for line in eachsplit(headers_raw, "\r\n"; keepempty=false)
        idx = findfirst(':', line)

        idx === nothing && continue

        key = strip(SubString(line, 1, prevind(line, idx)))
        val = strip(SubString(line, nextind(line, idx)))

        headers[String(key)] = String(val)
    end

    return headers
end

function _malloc_copy(bytes::Vector{UInt8})
    if isempty(bytes)
        return Ptr{UInt8}(C_NULL), Csize_t(0)
    end

    # Use the Rust library's malloc to ensure heap compatibility on Windows
    ptr = ccall(
        (:fmh_malloc, _load_rust_lib()),
        Ptr{UInt8},
        (Csize_t,),
        length(bytes)
    )
    ptr == C_NULL && error("malloc failed for response buffer via Rust fmh_malloc")
    unsafe_copyto!(ptr, pointer(bytes), length(bytes))
    return ptr, Csize_t(length(bytes))
end

function _active_app_or_throw()
    app = _active_app[]
    app isa App || error("No active Fomalhaut app registered")
    return app::App
end

"""
    _match_dynamic_path(pattern, actual) -> Bool

Check if `actual` path matches `pattern` that may contain `:param` segments.
Example : _match_dynamic_path("/v1/users/:id", "/v1/users/user-123") -> true
"""
function _match_dynamic_path(pattern::String, actual::String)::Bool
    p_it = eachsplit(pattern, '/'; keepempty=false)
    a_it = eachsplit(actual, '/'; keepempty=false)
    p_state = iterate(p_it)
    a_state = iterate(a_it)

    while true
        if p_state === nothing && a_state === nothing
            return true
        elseif p_state === nothing || a_state === nothing
            return false
        end

        p_seg, p_next = p_state
        a_seg, a_next = a_state

        if !startswith(p_seg, ':') && p_seg != a_seg
            return false
        end

        p_state = iterate(p_it, p_next)
        a_state = iterate(a_it, a_next)
    end
end

"""
    _extract_path_params(pattern, actual) -> Dict{String, String}

Extract dynamic segment values from `actual` path given a `pattern`.
Example : _extract_path_params("/v1/users/:id", "/v1/users/user-123") -> Dict("id" => "user-123")
"""
function _extract_path_params(pattern::String, actual::String)::Dict{String, String}
    params = Dict{String, String}()
    a_it = eachsplit(actual, '/'; keepempty=false)
    a_state = iterate(a_it)

    for p_seg in eachsplit(pattern, '/'; keepempty=false)
        a_state === nothing && break
        a_seg, a_next = a_state
        if startswith(p_seg, ':')
            params[String(p_seg[2:end])] = String(a_seg)
        end
        a_state = iterate(a_it, a_next)
    end

    return params
end

"""
    _find_handler_with_params(app, method, path) -> (handler | nothing, params)

Look up the handler for `(method, path)` with two-phase matching :
1. Exact match - O(1), no allocation
2. Dynamic scan - checks registered patterns for `:param` segments
"""
function _find_handler_with_params(app::App, method::String, path::String)
    # Phase 1 : Exact match ( most common case, zero overhead )
    handler = get(app.http_routes, (method, path), nothing)
    if handler !== nothing
        return handler, Dict{String, String}()
    end

    # Phase 2 : Dynamic pattern scan
    for ((m, pattern), h) in app.http_routes
        if m == method && _match_dynamic_path(pattern, path)
            return h, _extract_path_params(pattern, path)
        end
    end

    return nothing, Dict{String, String}()
end

struct FFIHttpTaskData
    method_ptr::Ptr{UInt8}
    method_len::Csize_t
    path_ptr::Ptr{UInt8}
    path_len::Csize_t
    query_ptr::Ptr{UInt8}
    query_len::Csize_t
    headers_ptr::Ptr{UInt8}
    headers_len::Csize_t
    body_ptr::Ptr{UInt8}
    body_len::Csize_t
    task_handle::Ptr{Cvoid}
end
