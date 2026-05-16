import Fomalhaut as FMHUT

app = FMHUT.App()

# Mock Database
const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.get app "/v1/users" begin
    entries = ["$(id):$(name)" for (id, name) in MOCK_DB]
    response_text = join(entries, ", ")
    return (Vector{UInt8}(response_text), "text/plain", 200)
end

@FMHUT.post app "/v1/echo" begin
    return (copy(req.body), "application/json", 201)
end

@FMHUT.options app "/v1/echo" begin
    return (UInt8[], "text/plain", 204)
end

@FMHUT.put app "/v1/users/:id" begin
    user_id  = req.params["id"]
    new_name = String(copy(req.body))

    if haskey(MOCK_DB, user_id)
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id replaced. New name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id created with name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 201)
    end
end

@FMHUT.patch app "/v1/users/:id" begin
    user_id  = req.params["id"]
    new_name = String(copy(req.body))

    if haskey(MOCK_DB, user_id)
        old_name = MOCK_DB[user_id]
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id updated. $old_name -> $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $user_id not found."), "text/plain", 404)
    end
end

@FMHUT.delete app "/v1/users/:id" begin
    user_id = req.params["id"]

    if haskey(MOCK_DB, user_id)
        delete!(MOCK_DB, user_id)
        response_text = "User $user_id deleted. Remaining user(s) : $(length(MOCK_DB))"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $user_id not found."), "text/plain", 404)
    end
end

# Server Start
println("Fomalhaut Methods Test Server starting on http://127.0.0.1:8080")
FMHUT.serve(app; port=8080)

#=
Frontend Usage Examples :

// Step 1. GET all users
fetch("http://127.0.0.1:8080/v1/users").then(res => res.text()).then(data => console.log("GET all :", data));

// Step 2. POST Echo Test
fetch("http://127.0.0.1:8080/v1/echo", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message: "Hello Fomalhaut!" })
}).then(res => res.json()).then(data => console.log("POST Echo :", data));

// Step 3. PUT Test ( replace user-456 )
fetch("http://127.0.0.1:8080/v1/users/user-456", {
  method: "PUT",
  body: "Joseph"
}).then(res => res.text()).then(data => console.log("PUT :", data));

// Step 4. PATCH Test ( update user-123 )
fetch("http://127.0.0.1:8080/v1/users/user-123", {
  method: "PATCH",
  body: "Layla"
}).then(res => res.text()).then(data => console.log("PATCH :", data));

// Step 5. DELETE Test ( delete user-456 )
fetch("http://127.0.0.1:8080/v1/users/user-456", {
  method: "DELETE"
}).then(res => res.text()).then(data => console.log("DELETE :", data));

// Step 6. OPTIONS Test ( Preflight )
fetch("http://127.0.0.1:8080/v1/echo", {
  method: "OPTIONS",
  headers: {
    "Origin": "http://localhost:5173",
    "Access-Control-Request-Method": "POST",
    "Access-Control-Request-Headers": "Content-Type"
  }
}).then(res => console.log("OPTIONS Status :", res.status));
=#
