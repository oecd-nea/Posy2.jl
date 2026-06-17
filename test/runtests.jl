using POSY2
using Test
using XLSX

@testset verbose=true "POSY2" begin
    include("readdata/_includes.jl")
    include("components/_includes.jl")
    include("tools/_includes.jl")
    include("pp/_includes.jl")
end
