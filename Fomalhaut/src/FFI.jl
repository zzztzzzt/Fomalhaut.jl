# Manually Validated by zzztzzzt-SakuraAxis 2026-05-29

const _RUST_LIB_FILENAME =
    Sys.iswindows() ? "fomalhaut_rs.dll" :
    Sys.isapple()   ? "libfomalhaut_rs.dylib" :
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
        method = unsafe_string(method_ptr, method_len)
        path = unsafe_string(path_ptr, path_len)
        query = unsafe_string(query_ptr, query_len)
        headers_raw = unsafe_string(headers_ptr, headers_len)
        body = copy(unsafe_wrap(Vector{UInt8}, body_ptr, Int(body_len)))

        handler, path_params = _find_handler_with_params(app, method, path)
        if handler === nothing
            err_body, err_len = _malloc_copy(Vector{UInt8}(codeunits("Not Found")))
            err_ct, err_ct_len = _malloc_copy(Vector{UInt8}(codeunits("text/plain")))
            unsafe_store!(response_out, FFIHttpResponse(err_body, err_len, err_ct, err_ct_len, UInt16(404)))
            return Cint(0)
        end

        request = Request(method, path, _parse_headers(headers_raw), query, body, path_params)

        handler_result = handler(request)
        
        res_body, res_ct, res_status = if handler_result isa Tuple
            b  = length(handler_result) >= 1 ? handler_result[1] : UInt8[]
            ct = length(handler_result) >= 2 ? handler_result[2] : "text/plain"
            st = length(handler_result) >= 3 ? handler_result[3] : UInt16(200)
            b, ct, st
        else
            handler_result, "text/plain", UInt16(200)
        end

        # Force deep copy and convert to Vector{UInt8}
        final_body = Vector{UInt8}(copy(res_body))
        
        body_ptr_out, body_len_out = _malloc_copy(final_body)
        ct_bytes = Vector{UInt8}(codeunits(String(res_ct)))
        ct_ptr_out, ct_len_out = _malloc_copy(ct_bytes)


        unsafe_store!(
            response_out,
            FFIHttpResponse(body_ptr_out, body_len_out, ct_ptr_out, ct_len_out, UInt16(res_status)),
        )
        return Cint(0)
    catch err
        @error "Fomalhaut HTTP handler failed" exception=(err, catch_backtrace())
        try
            err_body, err_len = _malloc_copy(Vector{UInt8}(codeunits("Internal Server Error")))
            err_ct, err_ct_len = _malloc_copy(Vector{UInt8}(codeunits("text/plain")))
            unsafe_store!(response_out, FFIHttpResponse(err_body, err_len, err_ct, err_ct_len, UInt16(500)))
            return Cint(0)
        catch inner_err
            @error "Failed to allocate 500 response buffer" exception=inner_err
            return Cint(9)
        end
    end
end

function _ensure_http_callback()
    if _http_callback_ptr[] == C_NULL
        _http_callback_ptr[] = @cfunction(
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
    end
    return _http_callback_ptr[]
end
