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

function serve(app::App; host::AbstractString = "127.0.0.1", port::Integer = 8080, fps::Real = 30)
    1 <= port <= 65535 || error("port must be in 1:65535")
    (isempty(app.http_routes) && isempty(app.ws_routes) && isempty(app.native_routes)) && error("No routes registered on this App.")
    !_server_running[] || error("A Fomalhaut server is already running")

    addr = "$(host):$(port)"
    addr_bytes = Vector{UInt8}(codeunits(addr))
    _active_app[] = app
    push!(app.handler_refs, _ensure_http_callback())
    _register_routes!(app)

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
        while _server_running[]
            sleep(0.1)
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

    if app isa App
        _stop_ws_tasks!(app)
    end

    _active_app[] = nothing
    return nothing
end
