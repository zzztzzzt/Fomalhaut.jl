import Fomalhaut as FMHUT

app = FMHUT.App()

const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.delete app "/delete-user" (req) -> begin
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

FMHUT.serve(app; port=8080)

#=
Frontend Usage Example :

fetch("http://127.0.0.1:8080/delete-user", {
  method: "DELETE",
  body: "user-456"
})
.then(res => {
  console.log("Status ( Expected 200 ) :", res.status);
  return res.text();
})
.then(data => console.log("Response :", data));
=#
