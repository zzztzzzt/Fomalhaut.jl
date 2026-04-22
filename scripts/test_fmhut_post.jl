using Fomalhaut
app = App()
@post app "/echo" (req) -> begin
    my_response = copy(req.body)
    
    return (my_response, "application/json", 201)
end
serve(app; port=8080)

#=
Frontend Usage Example :

fetch("http://127.0.0.1:8080/echo", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Custom-Header": "Fomalhaut-Test"
  },
  body: JSON.stringify({ message: "Hello Fomalhaut!" })
})
.then(res => {
  console.log("Status ( Expected 201 ) :", res.status);
  return res.json();
})
.then(data => console.log("Echo Result :", data));
=#