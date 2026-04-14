const lines = [
":::::::::: ::::     ::::     :::     :::        :::    :::  :::    ::: ::::::::::: ",
":+:        +:+:+: :+:+:+   :+: :+:   :+:        :+:    :+:  :+:    :+:     :+:  ",
"+:+        +:+ +:+:+ +:+  +:+   +:+  +:+        +:+    +:+  +:+    +:+     +:+   ",
":#::+::#   +#+  +:+  +#+ +#++:++#++: +#+        +#++:++#++  +#+    +:+     +#+    ",
"+#+        +#+       +#+ +#+     +#+ +#+        +#+    +#+  +#+    +#+     +#+    ",
"#+#        #+#       #+# #+#     #+# #+#        #+#    #+#  #+#    #+#     #+#    ",
"###        ###       ### ###     ### ########## ###    ###   ########      ###    "
]

const max_len = maximum(length.(lines))

function lerp3(c1, c2, c3, t)
    t = clamp(t, 0.0, 1.0)
    f = t < 0.5 ? t * 2 : (t - 0.5) * 2
    base = t < 0.5 ? (c1, c2) : (c2, c3)
    return round.(Int, base[1] .+ (base[2] .- base[1]) .* f)
end

C1, C2, C3 = [150,50,230], [220,80,130], [255,140,0]

for line in lines
    padded = rpad(line, max_len)
    for (ci, ch) in enumerate(padded)
        t = max_len > 1 ? (ci - 1) / (max_len - 1) : 0.0
        r, g, b = lerp3(C1, C2, C3, t)
        print("\e[38;2;$(r);$(g);$(b)m$(ch)")
    end
    print("\e[0m\n")
end