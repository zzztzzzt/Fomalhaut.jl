import Fomalhaut as FMHUT

app = FMHUT.App()

@FMHUT.get app "/hello" (req) -> begin
    response_text = "Hello from Fomalhaut GET endpoint!"
    return (Vector{UInt8}(response_text), "text/plain", 200)
end

FMHUT.serve(app; port=8080)

#=
Frontend Usage Example :

fetch("http://127.0.0.1:8080/hello", {
  method: "GET"
})
.then(res => {
  console.log("Status ( Expected 200 ) :", res.status);
  return res.text();
})
.then(data => console.log("Response :", data));
=#
