import Fomalhaut as FMHUT

app = FMHUT.App()

# Mock Database
const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.get app "/v1/users" begin
    entries = ["$(id):$(name)" for (id, name) in MOCK_DB]
    response_text = join(entries, ", ")
    return (Vector{UInt8}(response_text), "text/plain", 200)
end

@FMHUT.get app @FMHUT.route("/v1/orgs/users", org_id::Int, user_id::String) begin
    if haskey(MOCK_DB, user_id)
        response_text = "org=$org_id user=$user_id name=$(MOCK_DB[user_id])"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $user_id not found in org $org_id."), "text/plain", 404)
    end
end

@FMHUT.post app "/v1/echo" begin
    return (copy(req.body), "application/json", 201)
end

@FMHUT.options app "/v1/echo" begin
    return (UInt8[], "text/plain", 204)
end

@FMHUT.put app @FMHUT.route("/v1/users", id::String) begin
    new_name = String(copy(req.body))

    if haskey(MOCK_DB, id)
        MOCK_DB[id] = new_name
        response_text = "User $id replaced. New name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        MOCK_DB[id] = new_name
        response_text = "User $id created with name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 201)
    end
end

@FMHUT.patch app @FMHUT.route("/v1/users", id::String) begin
    new_name = String(copy(req.body))

    if haskey(MOCK_DB, id)
        old_name = MOCK_DB[id]
        MOCK_DB[id] = new_name
        response_text = "User $id updated. $old_name -> $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $id not found."), "text/plain", 404)
    end
end

@FMHUT.delete app @FMHUT.route("/v1/users", id::String) begin
    if haskey(MOCK_DB, id)
        delete!(MOCK_DB, id)
        response_text = "User $id deleted. Remaining user(s) : $(length(MOCK_DB))"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $id not found."), "text/plain", 404)
    end
end

# Server Start
println("Fomalhaut Methods Test Server starting on http://127.0.0.1:8080")
FMHUT.serve(app; port=8080, allowed_origins=["*"])

#=
Frontend Usage Examples :

// Step 1. GET all users
fetch("http://127.0.0.1:8080/v1/users").then(res => res.text()).then(data => console.log("GET all :", data));

// Step 2. GET Multi Params Route ( org_id + user_id )
fetch("http://127.0.0.1:8080/v1/orgs/users/7/user-123")
  .then(res => res.text())
  .then(data => console.log("GET multi params :", data));

// Step 3. POST Echo Test
fetch("http://127.0.0.1:8080/v1/echo", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message: "Hello Fomalhaut!" })
}).then(res => res.json()).then(data => console.log("POST Echo :", data));

// Step 4. PUT Test ( replace user-456 )
fetch("http://127.0.0.1:8080/v1/users/user-456", {
  method: "PUT",
  body: "Joseph"
}).then(res => res.text()).then(data => console.log("PUT :", data));

// Step 5. PATCH Test ( update user-123 )
fetch("http://127.0.0.1:8080/v1/users/user-123", {
  method: "PATCH",
  body: "Layla"
}).then(res => res.text()).then(data => console.log("PATCH :", data));

// Step 6. DELETE Test ( delete user-456 )
fetch("http://127.0.0.1:8080/v1/users/user-456", {
  method: "DELETE"
}).then(res => res.text()).then(data => console.log("DELETE :", data));

// Step 7. OPTIONS Test ( Preflight )
fetch("http://127.0.0.1:8080/v1/echo", {
  method: "OPTIONS",
  headers: {
    "Origin": "http://localhost:5173",
    "Access-Control-Request-Method": "POST",
    "Access-Control-Request-Headers": "Content-Type"
  }
}).then(res => console.log("OPTIONS Status :", res.status));
=#
