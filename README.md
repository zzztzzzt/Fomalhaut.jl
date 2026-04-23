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
[![SakuraEngine.jl](https://img.shields.io/badge/SakuraEngine.jl-9558B2?style=for-the-badge&logo=julia&logoColor=white)](https://github.com/zzztzzzt/SakuraEngine.jl)

**[ for Dependencies Details please see the end of this README ]**

Fomalhaut uses Tokio & tokio-tungstenite to build Asynchronous WebSocket. Tokio & tokio-tungstenite licensed under the MIT License.

Fomalhaut provides first-class support for SakuraEngine.jl - the Template Engine for Julia.

## WIP Project Fomalhaut

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

### **POST** Registrations

run below to test `@FMHUT.post`

( Front-end example is in this file too, just copy & paste it to browser console )

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

### **GET** Registrations

run below to test `@FMHUT.get`

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_get.jl`

```julia
import Fomalhaut as FMHUT

app = FMHUT.App()

@FMHUT.get app "/hello" (req) -> begin
    response_text = "Hello from Fomalhaut GET endpoint!"
    return (Vector{UInt8}(response_text), "text/plain", 200)
end

FMHUT.serve(app; port=8080)
```

### **DELETE** Registrations

run below to test `@FMHUT.delete`

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_delete.jl`

```julia
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
```

### **PUT** Registrations

run below to test `@FMHUT.put`

( Front-end example is in this file too, just copy & paste it to browser console )

```julia
import Fomalhaut as FMHUT

app = FMHUT.App()

const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.put app "/replace-user" (req) -> begin
    body_str = String(copy(req.body))
    
    parts = split(body_str, ":"; limit=2)
    if length(parts) != 2
        return (Vector{UInt8}("Error : Invalid body format. Expected 'ID:NewName'"), "text/plain", 400)
    end
    
    user_id = parts[1]
    new_name = parts[2]
    
    if haskey(MOCK_DB, user_id)
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id replaced completely. New name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        MOCK_DB[user_id] = new_name
        response_text = "User $user_id created successfully with name : $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 201) # 201 Created
    end
end

FMHUT.serve(app; port=8080)
```

### **PATCH** Registrations

run below to test `@FMHUT.patch`

( Front-end example is in this file too, just copy & paste it to browser console )

```julia
import Fomalhaut as FMHUT

app = FMHUT.App()

const MOCK_DB = Dict("user-123" => "Nora", "user-456" => "Alexander")

@FMHUT.patch app "/update-user" (req) -> begin
    body_str = String(copy(req.body))
    
    parts = split(body_str, ":"; limit=2)
    if length(parts) != 2
        return (Vector{UInt8}("Error : Invalid body format. Expected 'ID:NewName'"), "text/plain", 400)
    end
    
    user_id = parts[1]
    new_name = parts[2]
    
    if haskey(MOCK_DB, user_id)
        old_name = MOCK_DB[user_id]
        MOCK_DB[user_id] = new_name
        
        response_text = "User $user_id updated successfully. $old_name -> $new_name"
        return (Vector{UInt8}(response_text), "text/plain", 200)
    else
        return (Vector{UInt8}("Error : User $user_id not found."), "text/plain", 404)
    end
end

FMHUT.serve(app; port=8080)
```

### **OPTIONS** Registrations

run below to test `@FMHUT.options`

( Front-end example is in this file too, just copy & paste it to browser console )

`julia --project=. --threads=auto scripts/test_fmhut_options.jl`

```julia
import Fomalhaut as FMHUT

app = FMHUT.App()

@FMHUT.post app "/echo" (req) -> begin
    return (copy(req.body), "application/json", 201)
end

@FMHUT.options app "/echo" (req) -> begin
    return (UInt8[], "text/plain", 204)
end

FMHUT.serve(app; port=8080)
```

## Project Dependencies Details

Tokio License : [https://github.com/tokio-rs/tokio/blob/master/LICENSE](https://github.com/tokio-rs/tokio/blob/master/LICENSE)
<br>

tokio-tungstenite License : [https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE](https://github.com/snapview/tokio-tungstenite/blob/master/LICENSE)
