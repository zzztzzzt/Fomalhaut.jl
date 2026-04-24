import Fomalhaut as FMHUT

# This example demonstrates the general route path, allowing developers to use 
# any Julia ORM or database driver ( e.g., SearchLight.jl, Octo.jl ).

app = FMHUT.App()

# [GET] Read record
@FMHUT.get app "/users/:id" (req) -> begin
    # Developer can perform any DB operations here:
    # user = DBInterface.execute(db, "SELECT * FROM users WHERE id = ?", [req.params["id"]])
    println("Julia Logic : GET User $(req.params["id"])")
    return (Vector{UInt8}("{\"id\": $(req.params["id"]), \"source\": \"Julia-Side\"}"), "application/json", 200)
end

# [POST] Create record
@FMHUT.post app "/users" (req) -> begin
    # Perform data validation or transformation here
    println("Julia Logic : POST User with body length $(length(req.body))")
    return (Vector{UInt8}("{\"status\": \"created\"}"), "application/json", 201)
end

# [PUT] Full update ( Replace )
@FMHUT.put app "/users/:id" (req) -> begin
    println("Julia Logic : PUT ( Replace ) User $(req.params["id"])")
    return (Vector{UInt8}("{\"status\": \"replaced\"}"), "application/json", 200)
end

# [PATCH] Partial update
@FMHUT.patch app "/users/:id" (req) -> begin
    println("Julia Logic : PATCH ( Update ) User $(req.params["id"])")
    return (Vector{UInt8}("{\"status\": \"updated\"}"), "application/json", 200)
end

# [DELETE] Delete record
@FMHUT.delete app "/users/:id" (req) -> begin
    println("Julia Logic : DELETE User $(req.params["id"])")
    return (Vector{UInt8}("{\"status\": \"deleted\"}"), "application/json", 200)
end

println("Fomalhaut Server ( General Path - All Methods ) starting...")
FMHUT.serve(app; port=8080)
