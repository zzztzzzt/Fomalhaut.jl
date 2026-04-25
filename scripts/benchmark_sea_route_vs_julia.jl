import Fomalhaut as FMHUT
using SearchLight, SearchLightSQLite
using JSON
using HTTP
using Dates
using Statistics
using Logging

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
    rows = [Dict(String(col) => data[i, col] for col in names(data)) for i in 1:size(data, 1)]
    return Vector{UInt8}(JSON.json(rows)), "application/json"
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

# Warmup Phase ( To eliminate Julia JIT overhead )
println("Warming up JIT compiler...")
HTTP.get("http://127.0.0.1:8081/julia/data")
HTTP.get("http://127.0.0.1:8081/rust/data?limit=5000")
println("Warmup complete.\n")

# Disable all Info logging for the actual benchmark runs
global_logger(ConsoleLogger(stderr, Logging.Warn))

try
    julia_avg = run_benchmark("http://127.0.0.1:8081/julia/data", "Standard Julia Path")
    rust_avg = run_benchmark("http://127.0.0.1:8081/rust/data?limit=5000", "Native Rust Path")

    speedup = julia_avg / rust_avg

    println("||||||  SPEEDUP : $(round(speedup, digits=2))x FASTER  ||||||")
finally
    FMHUT.stop_server!()
end
