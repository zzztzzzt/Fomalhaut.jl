import Fomalhaut as FMHUT

app = FMHUT.App()

const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.patch app "/update-user" (req) -> begin
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

FMHUT.serve(app; port=8080)

#=
Frontend Usage Example :

fetch("http://127.0.0.1:8080/update-user", {
  method: "PATCH",
  body: "user-123:Layla"
})
.then(res => {
  console.log("Status ( Expected 200 ) :", res.status);
  return res.text();
})
.then(data => console.log("Response :", data));
=#
