import Fomalhaut as FMHUT

# This example demonstrates specialized routes that bypass the Julia VM, 
# operating directly via SeaORM in the Rust layer.

app = FMHUT.App()

# [SEA_GET] Native Read
@FMHUT.sea_get app "/api/users/:id" "User"

# [SEA_POST] Native Create ( Auto-parses body to SeaORM ActiveModel )
@FMHUT.sea_post app "/api/users" "User"

# [SEA_PUT] Native Full Update
@FMHUT.sea_put app "/api/users/:id" "User"

# [SEA_PATCH] Native Partial Update
@FMHUT.sea_patch app "/api/users/:id" "User"

# [SEA_DELETE] Native Delete
@FMHUT.sea_delete app "/api/users/:id" "User"

println("Fomalhaut Server ( SeaORM Path - All Methods ) starting...")
# Once implemented, these routes will execute entirely in Rust for maximum performance.
FMHUT.serve(app; port=8080)

#=
Architectural Vision :
When @FMHUT.sea_xxx is called :
1. A NativeHandler is registered in the Rust ServerState.
2. Incoming requests bypass FFI and trigger the SeaORM module directly.
3. If the "User" entity is not defined in Rust, a runtime or startup error is triggered.
=#
