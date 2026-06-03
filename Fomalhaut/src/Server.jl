function _build_envelope_v1(
    payload::AbstractVector{UInt8};
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
    copyto!(frame, ENVELOPE_HEADER_LEN + 1, payload, firstindex(payload), payload_len)
    return frame
end

function _register_routes!(app::App)
    for ((method, path), handler) in app.http_routes
        method_bytes = Vector{UInt8}(codeunits(method))
        path_bytes = Vector{UInt8}(codeunits(path))
        status = ccall(
            (:fmh_register_http, _load_rust_lib()),
            Cint,
            (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ptr{Cvoid}),
            method_bytes,
            length(method_bytes),
            path_bytes,
            length(path_bytes),
            _ensure_http_callback(),
            C_NULL,
        )
        _check_ffi_status(status, "register_http $method $path")
    end

    for ((method, path), entity) in app.native_routes
        method_bytes = Vector{UInt8}(codeunits(method))
        path_bytes = Vector{UInt8}(codeunits(path))
        entity_bytes = Vector{UInt8}(codeunits(entity))
        status = ccall(
            (:fmh_register_native_route, _load_rust_lib()),
            Cint,
            (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
            method_bytes,
            length(method_bytes),
            path_bytes,
            length(path_bytes),
            entity_bytes,
            length(entity_bytes),
        )
        _check_ffi_status(status, "register_native_route $method $path -> $entity")
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
    payload::AbstractVector{UInt8};
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
                    if data !== nothing
                        _send_ws_data(path, data)
                    end
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

function connect_db(url::AbstractString)
    url_bytes = Vector{UInt8}(codeunits(url))
    status = ccall(
        (:fmh_db_connect, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t),
        url_bytes,
        length(url_bytes),
    )
    _check_ffi_status(status, "connect_db $url")
    return nothing
end

function _set_allowed_origins!(allowed_origins::AbstractVector{<:AbstractString})
    origins = String.(allowed_origins)
    any(origin -> occursin('\n', origin) || occursin('\r', origin), origins) && error("CORS origins must not contain newlines")

    origins_bytes = Vector{UInt8}(codeunits(join(origins, "\n")))
    status = ccall(
        (:fmh_set_allowed_origins, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t),
        origins_bytes,
        length(origins_bytes),
    )
    _check_ffi_status(status, "set_allowed_origins")
    return nothing
end

function _http_inflight_count()
    # atomic_add!(x, 0) returns the previous value; atomic_load is not in all Julia versions
    return Threads.atomic_add!(_http_inflight, 0)
end

function _wait_http_handlers!()
    while _http_inflight_count() > 0
        yield()
    end
    return nothing
end

function _spawn_http_handler!(data::FFIHttpTaskData)
    Threads.atomic_add!(_http_inflight, 1)
    Threads.@spawn try
        _handle_http_task(data)
    finally
        Threads.atomic_sub!(_http_inflight, 1)
    end
    return nothing
end

function _handle_http_task(data::FFIHttpTaskData)
    try
        app = _active_app_or_throw()

        method = unsafe_string(data.method_ptr, data.method_len)
        path = unsafe_string(data.path_ptr, data.path_len)
        query = unsafe_string(data.query_ptr, data.query_len)
        headers_raw = unsafe_string(data.headers_ptr, data.headers_len)
        body = copy(unsafe_wrap(Vector{UInt8}, data.body_ptr, Int(data.body_len)))

        handler, path_params, query_specs = _find_handler_with_params(app, method, path)

        if handler === nothing
            err_body, err_len = _malloc_copy(Vector{UInt8}(codeunits("Not Found")))
            err_ct, err_ct_len = _malloc_copy(Vector{UInt8}(codeunits("text/plain")))
            _complete_task(data.task_handle, UInt16(404), err_body, err_len, err_ct, err_ct_len)
            return
        end

        query_params = _coerce_query_params(query, query_specs)
        request = Request(method, path, _parse_headers(headers_raw), query, body, path_params, query_params)
        handler_result = handler(request)

        res_body, res_ct, res_status = if handler_result isa Tuple
            b = length(handler_result) >= 1 ? handler_result[1] : UInt8[]
            ct = length(handler_result) >= 2 ? handler_result[2] : "text/plain"
            st = length(handler_result) >= 3 ? handler_result[3] : UInt16(200)
            b, ct, st
        else
            handler_result, "text/plain", UInt16(200)
        end

        final_body = Vector{UInt8}(copy(res_body))
        body_ptr_out, body_len_out = _malloc_copy(final_body)
        ct_bytes = Vector{UInt8}(codeunits(String(res_ct)))
        ct_ptr_out, ct_len_out = _malloc_copy(ct_bytes)

        _complete_task(data.task_handle, UInt16(res_status), body_ptr_out, body_len_out, ct_ptr_out, ct_len_out)

    catch err
        @error "Fomalhaut HTTP task handler failed" exception=(err, catch_backtrace())
        try
            status = err isa HTTPBadRequest ? UInt16(400) : UInt16(500)
            message = err isa HTTPBadRequest ? err.message : "Internal Server Error"
            err_body, err_len = _malloc_copy(Vector{UInt8}(codeunits(message)))
            err_ct, err_ct_len = _malloc_copy(Vector{UInt8}(codeunits("text/plain")))
            _complete_task(data.task_handle, status, err_body, err_len, err_ct, err_ct_len)
        catch inner_err
            @error "Failed to send 500 response" exception=inner_err
        end
    end
end

function _complete_task(task_ptr, status_code, body_ptr, body_len, ct_ptr, ct_len)
    ccall(
        (:fmh_complete_http_task, _load_rust_lib()),
        Cint,
        (Ptr{Cvoid}, UInt16, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        task_ptr,
        status_code,
        body_ptr,
        body_len,
        ct_ptr,
        ct_len,
    )
    return nothing
end

function serve(
    app::App;
    host::AbstractString = "127.0.0.1",
    port::Integer = 8080,
    fps::Real = 30,
    allowed_origins::AbstractVector{<:AbstractString} = String[],
)
    try
        AsciiArt.print_fomalhaut_ascii_art()
    catch err
        @warn "Failed to show Fomalhaut ASCII art." exception = (err, catch_backtrace())
    end

    1 <= port <= 65535 || error("port must be in 1:65535")
    (isempty(app.http_routes) && isempty(app.ws_routes) && isempty(app.native_routes)) && error("No routes registered on this App.")
    !_server_running[] || error("A Fomalhaut server is already running")

    addr = "$(host):$(port)"
    addr_bytes = Vector{UInt8}(codeunits(addr))
    _active_app[] = app
    _register_routes!(app)
    _set_allowed_origins!(allowed_origins)

    # AsyncCondition notifier : Rust wakes the poll loop via uv_async_send ( no sleep polling )
    cond = Base.AsyncCondition()
    _http_notifier_cond[] = cond

    # NOTE : uv_async_send is thread-safe; DO NOT call any other Julia API in this callback
    notify_cb = @cfunction(
        (handle::Ptr{Cvoid}) -> (ccall(:uv_async_send, Cint, (Ptr{Cvoid},), handle); nothing),
        Cvoid, (Ptr{Cvoid},)
    )
    _http_notifier_cb[] = notify_cb

    notifier_status = ccall(
        (:fmh_set_http_notifier, _load_rust_lib()),
        Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}),
        notify_cb,
        cond.handle,
    )
    _check_ffi_status(notifier_status, "fmh_set_http_notifier")

    _server_running[] = true
    
    # Start Rust server ( now returns immediately after binding )
    status = ccall(
        (:fmh_server_start, _load_rust_lib()),
        Cint,
        (Ptr{UInt8}, Csize_t),
        addr_bytes,
        length(addr_bytes),
    )
    
    if status != 0
        _server_running[] = false
        _check_ffi_status(status, "fmh_server_start")
    end

    _start_ws_tasks!(app; fps = fps)

    try
        cond = _http_notifier_cond[]
        while _server_running[]
            # Drain loop
            # After each wakeup ( or at startup ), exhaust ALL pending tasks before
            # going back to wait(). This is mandatory because uv_async_send
            # coalesces multiple signals : 5 rapid requests may only fire 1 wakeup
            drained = false
            while !drained && _server_running[]
                task_data = Ref(FFIHttpTaskData(
                    C_NULL, 0, C_NULL, 0, C_NULL, 0, C_NULL, 0, C_NULL, 0, C_NULL
                ))
                status = ccall(
                    (:fmh_poll_http_task, _load_rust_lib()),
                    Cint,
                    (Ptr{FFIHttpTaskData},),
                    task_data,
                )

                if status == 11 # FFI_OK_WITH_TASK
                    _spawn_http_handler!(task_data[])
                else
                    drained = true # Channel empty; exit inner loop
                end
            end

            if _server_running[]
                wait(cond)
            end
        end
    catch err
        if err isa InterruptException
            @info "Interrupt received ( Ctrl-C / Break )"
        else
            rethrow(err)
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

    # Unblock the main loop's wait( cond ) so it can observe _server_running[] == false
    cond = _http_notifier_cond[]
    if cond isa Base.AsyncCondition
        ccall(:uv_async_send, Cint, (Ptr{Cvoid},), cond.handle)
    end
    _wait_http_handlers!()

    _http_notifier_cond[] = nothing
    _http_notifier_cb[]   = nothing

    if app isa App
        _stop_ws_tasks!(app)
    end

    _active_app[] = nothing
    return nothing
end
