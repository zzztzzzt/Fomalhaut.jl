import Fomalhaut as FMHUT
using SearchLight, SearchLightSQLite
using SearchLight.Migrations

function create_demo_schema()
    SearchLight.connect(
        Dict(
            "adapter" => "SQLite",
            "database" => "fomalhaut_demo.db"
        )
    )

    # Avoid duplicate creation
    SearchLight.query("DROP TABLE IF EXISTS users")

    SearchLight.Migrations.create_table(:users) do
        [
            SearchLight.Migrations.column(:id, :int, "PRIMARY KEY AUTOINCREMENT"),
            SearchLight.Migrations.column(:name, :string),
            SearchLight.Migrations.column(:email, :string)
        ]
    end

    SearchLight.query("""
        INSERT INTO users (name, email)
        VALUES ('SearchLight User', 'sl@fomalhaut.io')
    """)

    println("SearchLight : Schema created and data seeded.")
end

app = FMHUT.App()

create_demo_schema()

# Fomalhaut connects to the same SQLite file ( used by Rust SeaORM )
FMHUT.connect_db("sqlite://fomalhaut_demo.db")

# Register Rust native routes
@FMHUT.sea_get app @FMHUT.route("/api/v1/users", id::Int) "users"
@FMHUT.sea_post app "/api/v1/users" "users"
@FMHUT.sea_put app @FMHUT.route("/api/v1/users", id::Int) "users"
@FMHUT.sea_patch app @FMHUT.route("/api/v1/users", id::Int) "users"
@FMHUT.sea_delete app @FMHUT.route("/api/v1/users", id::Int) "users"

println("Fomalhaut : Native SeaORM routes registered")
println("Server starting at http://127.0.0.1:8080")

FMHUT.serve(app; port=8080, allowed_origins=["*"])

#=
Frontend Usage Examples :

// Step 1. GET Test ( Fetch user 1 )
fetch("http://127.0.0.1:8080/api/v1/users/1").then(res => res.json()).then(data => console.log("GET :", data));

// Step 2. POST Test ( Create a new user )
fetch("http://127.0.0.1:8080/api/v1/users", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "Alice", email: "alice@fomalhaut.io" })
}).then(res => res.json()).then(data => console.log("POST :", data));

// Step 3. PUT Test ( Replace user 1 data )
fetch("http://127.0.0.1:8080/api/v1/users/1", {
  method: "PUT",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name: "SearchLight User Updated", email: "sl_updated@fomalhaut.io" })
}).then(res => res.json()).then(data => console.log("PUT :", data));

// Step 4. PATCH Test ( Update only user 1's email )
fetch("http://127.0.0.1:8080/api/v1/users/1", {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ email: "sl_patched@fomalhaut.io" })
}).then(res => res.json()).then(data => console.log("PATCH :", data));

// Step 5. DELETE Test ( Delete user 1 )
fetch("http://127.0.0.1:8080/api/v1/users/1", {
  method: "DELETE"
}).then(res => res.json()).then(data => console.log("DELETE :", data));
=#

