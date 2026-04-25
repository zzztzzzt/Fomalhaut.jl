function _validate_path(path::AbstractString)
    startswith(path, "/") || error("path must start with '/'")
    occursin("*", path) && error("wildcard routes are not supported in v0.2")
    return path
end

function register_http!(app::App, method::AbstractString, path::AbstractString, handler::Function)
    normalized_method = uppercase(String(method))
    app.http_routes[(normalized_method, String(_validate_path(path)))] = handler
    return app
end

function register_sea_http!(app::App, method::AbstractString, path::AbstractString, entity::AbstractString)
    normalized_method = uppercase(String(method))
    app.native_routes[(normalized_method, String(_validate_path(path)))] = String(entity)
    return app
end

# Methods wrappers
function register_get!(app::App, path::AbstractString, handler::Function)
    return register_http!(app, "GET", path, handler)
end

function register_post!(app::App, path::AbstractString, handler::Function)
    return register_http!(app, "POST", path, handler)
end

function register_put!(app::App, path::AbstractString, handler::Function)
    return register_http!(app, "PUT", path, handler)
end

function register_patch!(app::App, path::AbstractString, handler::Function)
    return register_http!(app, "PATCH", path, handler)
end

function register_delete!(app::App, path::AbstractString, handler::Function)
    return register_http!(app, "DELETE", path, handler)
end

function register_options!(app::App, path::AbstractString, handler::Function)
    return register_http!(app, "OPTIONS", path, handler)
end

function register_websocket!(app::App, path::AbstractString, handler::Function)
    app.ws_routes[String(_validate_path(path))] = handler
    return app
end

# Macros
macro get(app, path, f)
    return esc(quote
        $(@__MODULE__).register_get!($app, $path, (req) -> $f)
    end)
end

macro post(app, path, f)
    return esc(quote
        $(@__MODULE__).register_post!($app, $path, (req) -> $f)
    end)
end

macro put(app, path, f)
    return esc(quote
        $(@__MODULE__).register_put!($app, $path, (req) -> $f)
    end)
end

macro patch(app, path, f)
    return esc(quote
        $(@__MODULE__).register_patch!($app, $path, (req) -> $f)
    end)
end

macro delete(app, path, f)
    return esc(quote
        $(@__MODULE__).register_delete!($app, $path, (req) -> $f)
    end)
end

macro options(app, path, f)
    return esc(quote
        $(@__MODULE__).register_options!($app, $path, (req) -> $f)
    end)
end

macro websocket(app, path, f)
    return esc(quote
        $(@__MODULE__).register_websocket!($app, $path, $f)
    end)
end

# SeaORM Specialized Macros
macro sea_get(app, path, entity)
    return esc(quote
        $(@__MODULE__).register_sea_http!($app, "GET", $path, $entity)
    end)
end

macro sea_post(app, path, entity)
    return esc(quote
        $(@__MODULE__).register_sea_http!($app, "POST", $path, $entity)
    end)
end

macro sea_put(app, path, entity)
    return esc(quote
        $(@__MODULE__).register_sea_http!($app, "PUT", $path, $entity)
    end)
end

macro sea_patch(app, path, entity)
    return esc(quote
        $(@__MODULE__).register_sea_http!($app, "PATCH", $path, $entity)
    end)
end

macro sea_delete(app, path, entity)
    return esc(quote
        $(@__MODULE__).register_sea_http!($app, "DELETE", $path, $entity)
    end)
end
