import Fomalhaut as FMHUT
using SearchLight, SearchLightSQLite
using JSON
using HTTP
using Dates
using Statistics

# 1. Setup Database with 5,000 records
db_path = "benchmark_test.db"
isfile(db_path) && rm(db_path)

SearchLight.connect(Dict("adapter" => "SQLite", "database" => db_path))
SearchLight.query("CREATE TABLE sensor_data (id INTEGER PRIMARY KEY, value REAL, timestamp TEXT)")

println("Seeding 5000 records...")
SearchLight.query("BEGIN TRANSACTION")
for i in 1:5000
    SearchLight.query("INSERT INTO sensor_data (value, timestamp) VALUES ($(rand()), '$(now())')")
end
SearchLight.query("COMMIT")
println("Database ready.")

# 2. Define Server
app = FMHUT.App()

FMHUT.connect_db("sqlite://$db_path")

# [Path A] Standard Julia Route ( SearchLight -> JSON -> Rust -> Network )
@FMHUT.get app "/julia/data" begin
    data = SearchLight.query("SELECT * FROM sensor_data LIMIT 5000")
    # Simulate standard ORM to JSON workflow
    return Vector{UInt8}(JSON.json(data)), "application/json"
end

# [Path B] Native Rust Route ( SeaORM -> Rust -> Network )
# Zero FFI overhead, Native JSON serialization
@FMHUT.sea_get app "/rust/data" "sensor_data"

# Run server in background task
server_task = @async FMHUT.serve(app; port=8081)
sleep(2) # Wait for server to start

# 3. Run Benchmark
function run_benchmark(url, name, iterations=100)
    println("\nBenchmarking $name ($url)...")
    times = Float64[]
    for i in 1:iterations
        t = @elapsed HTTP.get(url)
        push!(times, t)
    end

    println("$name Results :")

    resp = HTTP.get(url)
    println("Payload Size :    $(length(resp.body)) bytes")

    println("Average Latency : $(round(mean(times) * 1000, digits=2)) ms")
    println("Min Latency :     $(round(min(times...) * 1000, digits=2)) ms")
    println("Max Latency :     $(round(max(times...) * 1000, digits=2)) ms")
    return mean(times)
end

try
    rust_avg = run_benchmark("http://127.0.0.1:8081/rust/data?limit=5000", "Native Rust Path")
    julia_avg = run_benchmark("http://127.0.0.1:8081/julia/data", "Standard Julia Path")

    speedup = julia_avg / rust_avg

    println("||||||  SPEEDUP : $(round(speedup, digits=2))x FASTER  ||||||")
finally
    FMHUT.stop_server!()
end
