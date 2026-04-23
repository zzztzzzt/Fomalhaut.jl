# Fomalhaut.jl

[![GitHub last commit](https://img.shields.io/github/last-commit/zzztzzzt/Fomalhaut.jl.svg)](https://github.com/zzztzzzt/Fomalhaut.jl)
[![GitHub repo size](https://img.shields.io/github/repo-size/zzztzzzt/Fomalhaut.jl.svg)](https://github.com/zzztzzzt/Fomalhaut.jl)

<br>

<img src="https://github.com/zzztzzzt/Fomalhaut.jl/blob/main/logo/logo.webp" alt="fomalhaut-logo" style="height: 280px; width: auto;" />

### Fomalhaut - Velocity Edge Defined By Us. - Web Framework for 3D / Physical Data Transmission.

IMPORTANT : This project is still in the development and testing stages, licensing terms may be updated in the future. Please don't do any commercial usage currently.

## Project Dependencies Guide

[![Tokio](https://img.shields.io/badge/Tokio-F04D23?style=for-the-badge&logo=rust&logoColor=white)](https://github.com/tokio-rs/tokio)
[![tokio-tungstenite](https://img.shields.io/badge/tokio_tungstenite-F04D23?style=for-the-badge&logo=rust&logoColor=white)](https://github.com/snapview/tokio-tungstenite)
[![Julia](https://img.shields.io/badge/Julia-9558B2?style=for-the-badge&logo=julia&logoColor=white)](https://github.com/JuliaLang/julia)

**[ for Dependencies Details please see the end of this README ]**

Fomalhaut uses Tokio & tokio-tungstenite to build Asynchronous WebSocket. Tokio & tokio-tungstenite licensed under the MIT License.  

## WIP Project Fomalhaut

### **WebSocket** Registrations

run below to test `@FMHUT.websocket`

( Front-end fetch usage is in this file too, just copy & paste it to browser console )

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

### **POST** Registrations

run below to test `@FMHUT.post`

( Front-end fetch usage is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_post.jl`

```julia
import Fomalhaut as FMHUT

app = FMHUT.App()

@FMHUT.post app "/echo" (req) -> begin
    my_response = copy(req.body)
    
    return (my_response, "application/json", 201)
end

FMHUT.serve(app; port=8080)
```

## Project Dependencies Details

Tokio License : [https://github.com/tokio-rs/tokio/blob/master/LICENSE](https://github.com/tokio-rs/tokio/blob/master/LICENSE)
<br>

tokio-tungstenite License : [https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE](https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE)
