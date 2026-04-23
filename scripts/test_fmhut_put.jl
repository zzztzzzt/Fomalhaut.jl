import Fomalhaut as FMHUT

app = FMHUT.App()

const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.put app "/replace-user" (req) -> begin
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
        return (Vector{UInt8}(response_text), "text/plain", 201) # 201 Created
    end
end

FMHUT.serve(app; port=8080)

#=
Frontend Usage Example :

fetch("http://127.0.0.1:8080/replace-user", {
  method: "PUT",
  body: "user-456:Joseph"
})
.then(res => {
  console.log("Status ( Expected 200 ) :", res.status);
  return res.text();
})
.then(data => console.log("Response :", data));
=#
