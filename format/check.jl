# Check-mode JuliaFormatter. Set FORMAT_FIX=1 to write changes.
using JuliaFormatter

overwrite = get(ENV, "FORMAT_FIX", "0") == "1"
root = dirname(@__DIR__)
targets = (
    joinpath(root, "src"),
    joinpath(root, "test"),
    joinpath(root, "server.jl"),
    joinpath(root, "format", "check.jl"),
    joinpath(root, "qa", "check.jl"),
)

ok = true
for target in targets
    formatted = format(target; overwrite = overwrite, verbose = true)
    global ok = ok && formatted
end

if !ok && !overwrite
    println(stderr, "Julia sources are not formatted; run: make format-fix")
    exit(1)
end
