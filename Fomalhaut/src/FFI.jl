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
    p_parts = filter(!isempty, split(pattern, "/"))
    a_parts = filter(!isempty, split(actual, "/"))
    length(p_parts) != length(a_parts) && return false
    return all(((p, a),) -> startswith(p, ":") || p == a, zip(p_parts, a_parts))
end

"""
    _extract_path_params(pattern, actual) -> Dict{String, String}

Extract dynamic segment values from `actual` path given a `pattern`.
Example : _extract_path_params("/v1/users/:id", "/v1/users/user-123") -> Dict("id" => "user-123")
"""
function _extract_path_params(pattern::String, actual::String)::Dict{String, String}
    params = Dict{String, String}()
    p_parts = filter(!isempty, split(pattern, "/"))
    a_parts = filter(!isempty, split(actual, "/"))
    for (p, a) in zip(p_parts, a_parts)
        if startswith(p, ":")
            params[p[2:end]] = a   # strip the leading ':'
        end
    end
    return params
end

"""
    _find_handler_with_params(app, method, path) -> (handler | nothing, params)

Look up the handler for `(method, path)` with two-phase matching :
1. Exact match  — O(1), no allocation
2. Dynamic scan — checks registered patterns for `:param` segments
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
            return Cint(9)
        end

        request = Request(method, path, _parse_headers(headers_raw), query, body, path_params)

        handler_result = handler(request)
        
        res_body = UInt8[]
        res_ct = "text/plain"
        res_status = UInt16(200)

        if handler_result isa Tuple
            if length(handler_result) >= 2
                res_body = handler_result[1]
                res_ct = handler_result[2]
                if length(handler_result) >= 3
                    res_status = handler_result[3]
                end
            end
        else
            res_body = handler_result
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
        return Cint(9)
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
