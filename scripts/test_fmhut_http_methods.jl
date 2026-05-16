import Fomalhaut as FMHUT

app = FMHUT.App()

# Mock Database
const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.get app "/v1/greetings/hello" begin
    response_text = "Hello from Fomalhaut GET endpoint!"
    return (Vector{UInt8}(response_text), "text/plain", 200)
end

@FMHUT.post app "/v1/echo" begin
    return (copy(req.body), "application/json", 201)
end

@FMHUT.options app "/v1/echo" begin
    return (UInt8[], "text/plain", 204)
end

@FMHUT.put app "/v1/users" begin
    body_str = String(copy(req.body))
    parts = split(body_str, ":"; limit=2)
    if length(parts) != 2
        return (Vector{UInt8}("Error : Invalid body format. Expected 'ID:NewName'"), "text/plain", 400)
    end
    
    user_id = parts[1]
    new_name = parts[2]
    
    if haskey(MOCK_DB, user_id)
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id replaced completely. New name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id created successfully with name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 201)
    end
end

@FMHUT.patch app "/v1/users" begin
    body_str = String(copy(req.body))
    parts = split(body_str, ":"; limit=2)
    if length(parts) != 2
        return (Vector{UInt8}("Error : Invalid body format. Expected 'ID:NewName'"), "text/plain", 400)
    end
    
    user_id = parts[1]
    new_name = parts[2]
    
    if haskey(MOCK_DB, user_id)
        old_name = MOCK_DB[user_id]
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id updated successfully. $old_name -> $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $user_id not found."), "text/plain", 404)
    end
end

@FMHUT.delete app "/v1/users" begin
    user_id = String(copy(req.body))
    
    if haskey(MOCK_DB, user_id)
        delete!(MOCK_DB, user_id)
        response_text = "User $user_id deleted successfully. Remaining user(s) : $(length(MOCK_DB))"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        response_text = "Error : User $user_id not found."
        return (Vector{UInt8}(response_text), "text/plain", 404)
    end
end

# Server Start
println("Fomalhaut Methods Test Server starting on http://127.0.0.1:8080")
FMHUT.serve(app; port=8080)

#=
Frontend Usage Examples :

// Step 1. GET Test
fetch("http://127.0.0.1:8080/v1/greetings/hello").then(res => res.text()).then(data => console.log("GET :", data));

// Step 2. POST Test
fetch("http://127.0.0.1:8080/v1/echo", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message: "Hello Fomalhaut!" })
}).then(res => res.json()).then(data => console.log("POST Echo :", data));

// Step 3. PUT Test
fetch("http://127.0.0.1:8080/v1/users", {
  method: "PUT",
  body: "user-456:Joseph"
}).then(res => res.text()).then(data => console.log("PUT :", data));

// Step 4. PATCH Test
fetch("http://127.0.0.1:8080/v1/users", {
  method: "PATCH",
  body: "user-123:Layla"
}).then(res => res.text()).then(data => console.log("PATCH :", data));

// Step 5. DELETE Test
fetch("http://127.0.0.1:8080/v1/users", {
  method: "DELETE",
  body: "user-456"
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

