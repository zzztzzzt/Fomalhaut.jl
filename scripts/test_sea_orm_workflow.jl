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
@FMHUT.sea_get app "/api/users/:id" "users"

println("Fomalhaut : Native SeaORM route registered")
println("Server starting at http://127.0.0.1:8080")
println("Test command: curl http://127.0.0.1:8080/api/users/1")

FMHUT.serve(app; port=8080)
