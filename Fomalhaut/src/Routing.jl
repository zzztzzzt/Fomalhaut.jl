function _validate_path(path::AbstractString)
    startswith(path, "/") || error("path must start with '/'")
    occursin("*", path) && error("wildcard routes are not supported in v0.2")
    return String(path)
end

function _normalize_params(params)
    if params isa Pair
        return [_normalize_single_param(params)]
    elseif params isa Tuple || params isa AbstractVector
        isempty(params) && return Pair{String, DataType}[]
        return [_normalize_single_param(p) for p in params]
    else
        error("invalid route params format. Use Pair or tuple/vector of Pair{Symbol,DataType}.")
    end
end

function _normalize_single_param(param::Pair)
    key, typ = param
    key isa Symbol || error("route param name must be a Symbol, got $(typeof(key))")
    typ isa DataType || error("route param type must be a DataType, got $(typeof(typ))")
    return String(key) => typ
end

function _normalize_query_params(params)
    params === nothing && return QueryParamSpec[]
    if params isa QueryParamSpec
        return [params]
    elseif params isa Tuple || params isa AbstractVector
        isempty(params) && return QueryParamSpec[]
        return [_normalize_single_query_param(p) for p in params]
    else
        error("invalid query params format. Use QueryParamSpec or tuple/vector of QueryParamSpec.")
    end
end

function _normalize_single_query_param(param::QueryParamSpec)
    return param
end

function _to_route_spec(pathspec)::RouteSpec
    if pathspec isa AbstractString
        return RouteSpec(_validate_path(pathspec), Pair{String, DataType}[], QueryParamSpec[])
    elseif pathspec isa RouteSpec
        return RouteSpec(_validate_path(pathspec.path), pathspec.param_types, pathspec.query_params)
    elseif pathspec isa Pair
        base, params = pathspec
        base isa AbstractString || error("route base path must be AbstractString")
        normalized_base = _validate_path(base)
        normalized_params = _normalize_params(params)
        dynamic_path = isempty(normalized_params) ? normalized_base : string(normalized_base, "/", join((":" * name for (name, _) in normalized_params), "/"))
        return RouteSpec(dynamic_path, normalized_params, QueryParamSpec[])
    else
        error("invalid route declaration. Use \"/path\" for static routes or \"/path\" => (:id => Int) for dynamic routes.")
    end
end

function register_http!(app::App, method::AbstractString, pathspec, handler::Function)
    normalized_method = uppercase(String(method))
    spec = _to_route_spec(pathspec)
    route_key = (normalized_method, spec.path)
    app.http_routes[route_key] = handler
    app.http_route_param_types[route_key] = Dict(spec.param_types)
    app.http_route_query_params[route_key] = spec.query_params
    return app
end

function register_sea_http!(app::App, method::AbstractString, pathspec, entity::AbstractString)
    normalized_method = uppercase(String(method))
    spec = _to_route_spec(pathspec)
    route_key = (normalized_method, spec.path)
    app.native_routes[route_key] = String(entity)
    app.native_route_param_types[route_key] = Dict(spec.param_types)
    return app
end

# Methods wrappers
function register_get!(app::App, pathspec, handler::Function)
    return register_http!(app, "GET", pathspec, handler)
end

function register_post!(app::App, pathspec, handler::Function)
    return register_http!(app, "POST", pathspec, handler)
end

function register_put!(app::App, pathspec, handler::Function)
    return register_http!(app, "PUT", pathspec, handler)
end

function register_patch!(app::App, pathspec, handler::Function)
    return register_http!(app, "PATCH", pathspec, handler)
end

function register_delete!(app::App, pathspec, handler::Function)
    return register_http!(app, "DELETE", pathspec, handler)
end

function register_options!(app::App, pathspec, handler::Function)
    return register_http!(app, "OPTIONS", pathspec, handler)
end

function register_websocket!(app::App, path::AbstractString, handler::Function)
    app.ws_routes[String(_validate_path(path))] = handler
    return app
end

function _route_macro_params(path_expr)
    path_expr isa Expr || return Pair{Symbol, Any}[]
    path_expr.head == :macrocall || return Pair{Symbol, Any}[]
    macro_name = string(path_expr.args[1])
    occursin("@route", macro_name) || return Pair{Symbol, Any}[]

    params = Pair{Symbol, Any}[]
    for p in path_expr.args[3:end]
        p isa LineNumberNode && continue
        if p isa Expr && p.head == :(::) && length(p.args) == 2 && p.args[1] isa Symbol
            push!(params, (p.args[1]::Symbol) => p.args[2])
        end
    end
    return params
end

function _route_macro_query_params(path_expr)
    path_expr isa Expr || return Pair{Symbol, Any}[]
    path_expr.head == :macrocall || return Pair{Symbol, Any}[]
    macro_name = string(path_expr.args[1])
    occursin("@route", macro_name) || return Pair{Symbol, Any}[]

    for p in path_expr.args[3:end]
        p isa LineNumberNode && continue
        if p isa Expr && p.head == :call && p.args[1] == :Q
            return [_query_macro_param(q)[1] => _query_macro_param(q)[2] for q in p.args[2:end]]
        end
    end
    return Pair{Symbol, Any}[]
end

function _query_macro_param(expr)
    if expr isa Expr && (expr.head == :(=) || expr.head == :kw)
        typed = expr.args[1]
        typed isa Expr && typed.head == :(::) && length(typed.args) == 2 && typed.args[1] isa Symbol ||
            throw(ArgumentError("Query params must use `name::Type` or `name::Type = default`"))
        return (typed.args[1]::Symbol, typed.args[2])
    elseif expr isa Expr && expr.head == :(::) && length(expr.args) == 2 && expr.args[1] isa Symbol
        return (expr.args[1]::Symbol, expr.args[2])
    else
        throw(ArgumentError("Query params must use `name::Type` or `name::Type = default`"))
    end
end

function _build_handler_macro(__module__, app_expr, path_expr, body_expr, register_fn)
    params = _route_macro_params(path_expr)
    query_params = _route_macro_query_params(path_expr)

    bindings = Any[
        :(local $(name) = req.params[$(String(name))]::$(typ))
        for (name, typ) in params
    ]
    append!(bindings, Any[
        :(local $(name) = req.query_params[$(String(name))]::$(typ))
        for (name, typ) in query_params
    ])

    handler = if isempty(bindings)
        :((req) -> $(body_expr))
    else
        :((req) -> begin
            $(bindings...)
            $(body_expr)
        end)
    end

    return quote
        $(register_fn)($(app_expr), $(path_expr), $(handler))
    end |> esc
end

# Macros
macro get(app, path, f)
    return _build_handler_macro(__module__, app, path, f, :($(@__MODULE__).register_get!))
end

macro post(app, path, f)
    return _build_handler_macro(__module__, app, path, f, :($(@__MODULE__).register_post!))
end

macro put(app, path, f)
    return _build_handler_macro(__module__, app, path, f, :($(@__MODULE__).register_put!))
end

macro patch(app, path, f)
    return _build_handler_macro(__module__, app, path, f, :($(@__MODULE__).register_patch!))
end

macro delete(app, path, f)
    return _build_handler_macro(__module__, app, path, f, :($(@__MODULE__).register_delete!))
end

macro options(app, path, f)
    return _build_handler_macro(__module__, app, path, f, :($(@__MODULE__).register_options!))
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

macro route(path, params...)
    if isempty(params)
        return esc(path)
    end

    route_params = Any[]
    query_params = Any[]
    path_parts = Any[path]
    last_ends_slash = path isa AbstractString && endswith(path, "/")

    for p in params
        if p isa Expr && p.head == :call && p.args[1] == :Q
            isempty(query_params) || throw(ArgumentError("@route accepts only one Q(...) block"))
            append!(query_params, p.args[2:end])
            continue
        end
        if p isa AbstractString
            push!(path_parts, p)
            last_ends_slash = endswith(p, "/")
            continue
        end
        if p isa Expr && p.head == :(::) && length(p.args) == 2 && p.args[1] isa Symbol
            name = p.args[1]::Symbol
            last_ends_slash || push!(path_parts, "/")
            push!(path_parts, ":" * String(name))
            last_ends_slash = false
            push!(route_params, p)
            continue
        end
        push!(route_params, p)
    end

    pairs_expr = Vector{Any}(undef, length(route_params))
    param_names = String[]
    for (i, p) in enumerate(route_params)
        if !(p isa Expr && p.head == :(::) && length(p.args) == 2 && p.args[1] isa Symbol)
            throw(ArgumentError("@route params must use `name::Type`, e.g. @route(\"/v1/users\", id::Int)"))
        end
        name = p.args[1]::Symbol
        typ  = p.args[2]

        push!(param_names, String(name))
        pairs_expr[i] = Expr(:call, :(=>), String(name), typ)
    end

    query_exprs = Any[]
    for q in query_params
        required = true
        default = nothing
        typed = q
        if q isa Expr && (q.head == :(=) || q.head == :kw)
            typed = q.args[1]
            required = false
            default = q.args[2]
        end
        if !(typed isa Expr && typed.head == :(::) && length(typed.args) == 2 && typed.args[1] isa Symbol)
            throw(ArgumentError("Query params must use `name::Type` or `name::Type = default`"))
        end
        name = typed.args[1]::Symbol
        typ = typed.args[2]
        push!(query_exprs, Expr(:call, GlobalRef(@__MODULE__, :QueryParamSpec), String(name), typ, required, default))
    end

    params_expr = Expr(:typed_vcat, :(Pair{String, DataType}), pairs_expr...)
    query_expr = Expr(:typed_vcat, GlobalRef(@__MODULE__, :QueryParamSpec), query_exprs...)
    base_expr = Expr(:call, :string, path_parts...)

    return esc(Expr(:call, GlobalRef(@__MODULE__, :RouteSpec), base_expr, params_expr, query_expr))
end
