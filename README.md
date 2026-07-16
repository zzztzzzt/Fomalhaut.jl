# Fomalhaut.jl

[![GitHub last commit](https://img.shields.io/github/last-commit/zzztzzzt/Fomalhaut.jl.svg)](https://github.com/zzztzzzt/Fomalhaut.jl)
[![GitHub repo size](https://img.shields.io/github/repo-size/zzztzzzt/Fomalhaut.jl.svg)](https://github.com/zzztzzzt/Fomalhaut.jl)

<br>

<img src="https://github.com/SakuraAxis/Fomalhaut.jl/blob/main/logo/logo.webp" alt="fomalhaut-logo" style="height: 280px; width: auto;" />

### Fomalhaut - Velocity Edge Defined By Us. - Web Framework for 3D / Physical Data Transmission.

IMPORTANT : This project is still in the development and testing stages, licensing terms may be updated in the future. Please don't do any commercial usage currently.

## Project Dependencies Guide

[![Tokio](https://img.shields.io/badge/Tokio-F04D23?style=for-the-badge&logo=rust&logoColor=white)](https://github.com/tokio-rs/tokio)
[![tokio-tungstenite](https://img.shields.io/badge/tokio_tungstenite-F04D23?style=for-the-badge&logo=rust&logoColor=white)](https://github.com/snapview/tokio-tungstenite)
[![SeaORM](https://img.shields.io/badge/Sea_ORM-F04D23?style=for-the-badge&logo=rust&logoColor=white)](https://github.com/seaql/sea-orm)
[![Julia](https://img.shields.io/badge/Julia-9558B2?style=for-the-badge&logo=julia&logoColor=white)](https://github.com/JuliaLang/julia)
[![SakuraEngine.jl](https://img.shields.io/badge/SakuraEngine.jl-9558B2?style=for-the-badge&logo=julia&logoColor=white)](https://github.com/SakuraAxis/SakuraEngine.jl)

**[ for Dependencies Details please see the end of this README ]**

Fomalhaut uses Tokio & tokio-tungstenite to build Asynchronous WebSocket & full support for RESTful operations. Tokio & tokio-tungstenite licensed under the MIT License.

Fomalhaut provides first-class support for Sea ORM - powerful relational ORM for Rust. Sea ORM licensed under the MIT License & Apache-2.0 License.

Fomalhaut provides first-class support for SakuraEngine.jl - the Template Engine for Julia.

## WebSocket & RESTful API Services

### **WebSocket** Registrations

run below to test `@FMHUT.websocket`

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_websocket.jl`

```julia
import Fomalhaut as FMHUT

const RES = 96
const BUFFER = zeros(Float32, RES, RES)
const R = range(-3f0, 3f0, length=RES)

function wave_stream(ctx)
    t = Float32(ctx.time * 2.0)
    BUFFER .= sin.(R .+ t) .+ cos.(R' .+ t)

    return vec(BUFFER)
end

app = FMHUT.App()

@FMHUT.websocket app "/live-wave" wave_stream

FMHUT.serve(app; port=8080, fps=60)
```

### **RESTful API** Registrations

run below to test `@FMHUT.get`, `@FMHUT.post`, `@FMHUT.put`, `@FMHUT.patch`, `@FMHUT.delete`, `@FMHUT.options`

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_http_methods.jl`

```julia
import Fomalhaut as FMHUT

app = FMHUT.App()

# Mock Database
const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.get app "/v1/users" begin
    entries = ["$(id):$(name)" for (id, name) in MOCK_DB]
    response_text = join(entries, ", ")
    return (Vector{UInt8}(response_text), "text/plain", 200)
end

@FMHUT.get app @FMHUT.route("/v1/orgs/", org_id::Int,"/users/", user_id::String, Q(q::String = "123", limit::Int)) begin
    if !contains(user_id, q)
        return (Vector{UInt8}("Error : User ID '$user_id' does not match query filter '$q'."), "text/plain", 404)
    end

    if haskey(MOCK_DB, user_id)
        response_text = "Found user $(MOCK_DB[user_id]) with ID $user_id in org $org_id (query: q=$q, limit=$limit)"
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
```

## Specialized Native WebSocket ( Axis )

Fomalhaut supports a specialised webSocket that bypass the Julia VM for GPU compute
workloads using **Axis**.

### **Native WebSocket** Registrations

run below to test `@FMHUT.axis_websocket`:

put below folders to project-root ( from Axis project ) :

`Axis`, `axis_rs`

`julia` > `]` > `activate .` > `dev ./Axis` > `Ctrl + D` exit REPL

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_axis_websocket.jl`

```julia
import Fomalhaut as FMHUT

import Axis as AX

const RES = 96
const R = Float32[-3f0 + 6f0 * (i-1) / (RES-1) for i in 1:RES]

const OUT_BUFFER = Vector{Float32}(undef, RES * RES)

mutable struct WaveContext
    start_time_sec::Float64
    r::Ptr{Float32}
    res::Int32
    out::Ptr{Float32}
end

@AX.rust_code """
#[repr(C)]
pub struct WaveContext {
    pub start_time_sec: f64,
    pub r: *const f32,
    pub res: i32,
    pub out: *mut f32,
}
"""

@AX.rust_fn function _wave_native_frame(ctx::Ptr{Cvoid}, out_len::Ptr{Csize_t})::Ptr{UInt8}
    """
    let ctx = unsafe { &mut *(ctx as *mut WaveContext) };

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    if ctx.start_time_sec == 0.0 {
        ctx.start_time_sec = now;
    }
    let t = ((now - ctx.start_time_sec) * 2.0) as f32;

    let res = ctx.res as usize;
    let r = unsafe { std::slice::from_raw_parts(ctx.r, res) };
    let out = unsafe { std::slice::from_raw_parts_mut(ctx.out, res * res) };

    for i in 0..res {
        for j in 0..res {
            out[i * res + j] = (r[i] + t).sin() + (r[j] + t).cos();
        }
    }

    unsafe {
        *out_len = (res * res * 4) as usize;
        ctx.out as *mut u8
    }
    """
end

const _WAVE_CTX = Ref{WaveContext}()

function init!()
    _WAVE_CTX[] = WaveContext(0.0, pointer(R), Int32(RES), pointer(OUT_BUFFER))
end

function get_native_generator()
    ctx_ptr = Base.unsafe_convert(Ptr{Cvoid}, _WAVE_CTX)
    cb_ptr = AX._axis_rs_symbol(Symbol("_wave_native_frame"))
    return cb_ptr, ctx_ptr
end

init!()

axis_generated_dir = abspath(joinpath(@__DIR__, "..", "axis_rs"))
@info "Triggering Axis Rust code generator..." axis_generated_dir
AX.bridge_up(axis_generated_dir)

cb_ptr, ctx_ptr = get_native_generator()

app = FMHUT.App()

@FMHUT.axis_websocket app "/live-wave" 60.0 cb_ptr ctx_ptr

FMHUT.serve(app; port=8080, fps=60)
```

### Callback Signature

Your generator must be a Rust function (written with `@AX.rust_fn`) that
satisfies the following C ABI :

```
(userdata: *mut c_void, out_len: *mut usize) -> *const u8
```

| Parameter | Role |
|-----------|------|
| `userdata` | Opaque context pointer you pass at registration time (`ctx_ptr`). Carry GPU buffer IDs, simulation parameters, etc. |
| `out_len` | **Output**: write the byte-length of the payload here before returning. |
| **Return** | Pointer to the raw payload bytes. Must stay valid until the next invocation (use a pre-allocated static/global buffer). Return `null` or set `*out_len = 0` to skip a frame. |

`fomalhaut_rs` copies the bytes immediately, prepends the 17-byte
Fomalhaut v1 envelope ( with a live timestamp ), and sends the frame.
**You must never free this pointer between calls.**

### Limitations

| # | Limitation | Reason |
|---|------------|--------|
| 1 | **All per-frame logic must live inside `@AX.rust_fn`** | The hot-path loop runs in a Rust OS thread; you cannot interleave Julia code between frames. |
| 2 | **The payload buffer must be pre-allocated and pinned** | `fomalhaut_rs` holds a raw pointer; Julia's GC must never move or collect the backing memory. Use `const` global arrays or memory allocated on the Rust side. |
| 3 | **Dynamic parameter updates require shared atomic/Mutex state** | If you need to change simulation parameters at runtime ( e.g. from an HTTP handler ), write them into an atomically-accessible struct and pass its pointer as `ctx_ptr`. Do **not** read Julia globals from inside the Rust callback. |
| 4 | **Envelope content_type is always `FLOAT32_TENSOR` (0x0001)** | The native stream always tags frames as Float32 tensors. Custom content types require the standard `@FMHUT.websocket` route. |
| 5 | **FPS is a target, not a guarantee** | The OS thread uses `std::thread::sleep` for pacing; actual throughput depends on GPU readback latency and OS scheduling jitter. |
| 6 | **One callback per path** | Each path may only have one native generator registered. Re-registration is not supported; restart the server if the callback needs to change. |
| 7 | **No per-client context** | All connected clients on a path receive the same broadcast frame. Client-specific streaming requires the standard `@FMHUT.websocket` route. |

### Running the Benchmark Test

Run this to see the performance difference between Julia-related-version and Rust-native-version :

```bash
julia --project=. scripts/benchmark_axis_websocket_vs_julia.jl
```

## Specialized Native Routes ( SeaORM )

Fomalhaut supports specialized routes that bypass the Julia VM for maximum data throughput. These routes execute directly in the Rust layer using **SeaORM**.

### **Native ORM Routes** Registrations

run below to test `@FMHUT.sea_get`, `@FMHUT.sea_post`, `@FMHUT.sea_put`, `@FMHUT.sea_patch`, `@FMHUT.sea_delete`

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_sea_route.jl`

```julia
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
```

### Running the Benchmark Test

Run this to see the performance difference between Julia-side-ORM-query and Rust-side-native-query :

```bash
julia --project=. scripts/benchmark_sea_route_vs_julia.jl
```

## Project Dependencies Details

Tokio License : [https://github.com/tokio-rs/tokio/blob/master/LICENSE](https://github.com/tokio-rs/tokio/blob/master/LICENSE)
<br>

tokio-tungstenite License : [https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE](https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE)
<br>

Sea ORM License : [https://github.com/SeaQL/sea-orm/blob/master/LICENSE-MIT](https://github.com/SeaQL/sea-orm/blob/master/LICENSE-MIT) and [another Apache-2.0 License](https://github.com/SeaQL/sea-orm/blob/master/LICENSE-APACHE)
