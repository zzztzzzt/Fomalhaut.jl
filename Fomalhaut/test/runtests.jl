using Test
using Fomalhaut

@testset "App route registration" begin
    app = App()

    @post app "/infer" req -> (copy(req.body), "application/octet-stream")
    @websocket app "/stream" ctx -> UInt8[0x01, 0x02]

    @test haskey(app.http_routes, "/infer")
    @test haskey(app.ws_routes, "/stream")
end

@testset "HTTP trampoline" begin
    app = App()
    Fomalhaut._active_app[] = app
    @post app "/infer" req -> (vcat(req.body, UInt8[0xFF]), "application/octet-stream")

    method = UInt8['P', 'O', 'S', 'T']
    path = Vector{UInt8}(codeunits("/infer"))
    query = Vector{UInt8}(codeunits("mode=test"))
    headers = Vector{UInt8}(codeunits("content-type: application/octet-stream\r\nx-test: 1\r\n"))
    body = UInt8[0x10, 0x20]
    response = Ref(Fomalhaut.FFIHttpResponse(0x0000, Ptr{UInt8}(C_NULL), 0, Ptr{UInt8}(C_NULL), 0))

    status = Fomalhaut._http_request_trampoline(
        C_NULL,
        pointer(method),
        Csize_t(length(method)),
        pointer(path),
        Csize_t(length(path)),
        pointer(query),
        Csize_t(length(query)),
        pointer(headers),
        Csize_t(length(headers)),
        pointer(body),
        Csize_t(length(body)),
        Base.unsafe_convert(Ptr{Fomalhaut.FFIHttpResponse}, response),
    )

    @test status == 0
    stored = response[]
    out_body = copy(unsafe_wrap(Vector{UInt8}, stored.body_ptr, Int(stored.body_len)))
    out_content_type = String(copy(unsafe_wrap(Vector{UInt8}, stored.content_type_ptr, Int(stored.content_type_len))))
    Base.Libc.free(stored.body_ptr)
    Base.Libc.free(stored.content_type_ptr)

    @test out_body == UInt8[0x10, 0x20, 0xFF]
    @test out_content_type == "application/octet-stream"
    @test Fomalhaut._parse_headers(String(headers))["x-test"] == "1"

    Fomalhaut._active_app[] = nothing
end
