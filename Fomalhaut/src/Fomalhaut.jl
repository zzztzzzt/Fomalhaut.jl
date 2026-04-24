module Fomalhaut

using Libdl
include("AsciiArt.jl")

include("Types.jl")
include("FFI.jl")
include("Routing.jl")
include("Server.jl")

export App, Request, WebSocketContext, serve, stop_server!, connect_db
export @get, @post, @put, @patch, @delete, @options, @websocket
export @sea_get, @sea_post, @sea_put, @sea_patch, @sea_delete
export CONTENT_TYPE_FLOAT32_TENSOR, CONTENT_TYPE_JSON, CONTENT_TYPE_RGBA_FRAME

function __init__()
    try
        AsciiArt.print_fomalhaut_ascii_art()
    catch err
        @warn "Failed to show Fomalhaut ASCII art." exception = (err, catch_backtrace())
    end
end

end # module Fomalhaut
