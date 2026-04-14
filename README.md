# Fomalhaut.jl

[![GitHub last commit](https://img.shields.io/github/last-commit/zzztzzzt/Fomalhaut.jl.svg)](https://github.com/zzztzzzt/Fomalhaut.jl)
[![GitHub repo size](https://img.shields.io/github/repo-size/zzztzzzt/Fomalhaut.jl.svg)](https://github.com/zzztzzzt/Fomalhaut.jl)

<br>

<img src="https://github.com/zzztzzzt/Fomalhaut.jl/blob/main/logo/logo.webp" alt="fomalhaut-logo" style="height: 280px; width: auto;" />

### Fomalhaut - Velocity Edge Defined By Us. - WebSocket Framework for 3D / Physical Data Transmission.

IMPORTANT : This project is still in the development and testing stages, licensing terms may be updated in the future. Please don't do any commercial usage currently.

## Project Dependencies Guide

[![Tokio](https://img.shields.io/badge/Tokio-FF6F30?style=for-the-badge&logo=tokio&logoColor=black)](https://github.com/tokio-rs/tokio)
[![tokio-tungstenite](https://img.shields.io/badge/tokio_tungstenite-FF6F30?style=for-the-badge&logo=tokio&logoColor=black)](https://github.com/snapview/tokio-tungstenite)
[![Julia](https://img.shields.io/badge/Julia-9558B2?style=for-the-badge&logo=julia&logoColor=white)](https://github.com/JuliaLang/julia)

**[ for Dependencies Details please see the end of this README ]**

Fomalhaut uses Tokio & tokio-tungstenite to build Asynchronous WebSocket. Tokio & tokio-tungstenite licensed under the MIT License.  

## WebSocket Framework ( v0.1 )

Fomalhaut is organized as a Julia API layer + Rust transport core :

- Julia builds frame metadata and payload bytes.
- Rust manages websocket lifecycle and broadcast delivery.
- FFI boundary uses a stable `C ABI` with status codes.

### Envelope v1 ( Little Endian )

- `version: u8` ( currently `1` )
- `content_type: u16` ( `1=float32_tensor`, `2=json`, `3=rgba_frame` )
- `flags: u16`
- `timestamp_ns: u64`
- `payload_len: u32`
- `payload: [u8; payload_len]`

### Minimal usage from Julia

```julia
using Fomalhaut

start_server(host = "127.0.0.1", port = 8080)
send_frame!(UInt8[0x01, 0x02, 0x03]; content_type = CONTENT_TYPE_RGBA_FRAME)
stop_server!()
```

## How To Start Backend Server

### 1. Build Rust backend library

From repository root :

```bash
cd fomalhaut_rs
cargo build --release
```

### 2. TEMPORARY : Test With Achernar

copy `/Fomalhaut/` & `/fomalhaut_rs/` folder to `Achernar project root`

### 3. Stop backend server

```julia
stop_server!()
```

## Migration Note ( Old IPC Server )

The previous IPC bridge pattern ( `Sockets.listen` on named pipe / unix domain socket and Rust `ipc_reader` ) is now removed from the default architecture.

- Old flow : `Julia IPC socket -> Rust ipc_reader -> websocket`
- Current flow : `Julia ccall -> Rust fmh_ws_send -> websocket`

This makes payload shape dynamic and removes fixed frame-size assumptions.

## Temporary Copy To Another Project

If you temporarily copy Fomalhaut into another Julia project and want `using Fomalhaut` to work immediately, copy both folders:

- `Fomalhaut/`
- `fomalhaut_rs/`

Reason: `Fomalhaut/src/Fomalhaut.jl` looks for the Rust dynamic library under :

- `fomalhaut_rs/target/release/`
- `fomalhaut_rs/target/debug/`

### Do Rust build artifacts need to be copied?

Yes. The compiled Rust dynamic library must exist on the target side :

- Windows : `fomalhaut_rs.dll`
- Linux : `libfomalhaut_rs.so`
- macOS : `libfomalhaut_rs.dylib`

You can either :

- copy `fomalhaut_rs/target/release/` together, or
- copy source and run `cargo build --release` again in the other project.

If only `Fomalhaut/` is copied without Rust build output, `using Fomalhaut` can still load, but `start_server` and `send_frame!` will fail when trying to load the dynamic library.

## Project Dependencies Details

Tokio License : [https://github.com/tokio-rs/tokio/blob/master/LICENSE](https://github.com/tokio-rs/tokio/blob/master/LICENSE)
<br>

tokio-tungstenite License : [https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE](https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE)
