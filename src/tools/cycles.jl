"""
Cycle formalism for DC power flow: Kirchhoff voltage law on independent cycles.
"""

using Graphs: SimpleGraph, cycle_basis, add_edge!
using JuMP: @constraint

# Use undirected cycle basis to find a minimal set of independent cycles.
# This avoids redundant constraints: only a basis of cycles needs KVL enforced.
function gencycles(mat::Matrix{Float64})
    N = size(mat, 1)
    g = SimpleGraph(N)
    # edge exists if susceptance < 0 (AC interconnection with registered B)
    for i in 1:N, j in (i + 1):N
        mat[i, j] < 0.0 && add_edge!(g, i, j)
    end
    return cycle_basis(g)
end

"""
    cyclebasis(s::Snapshot)

Return a basis of independent cycles of the snapshot's AC network, each as the
node names it visits in order. These are the cycles [`applydcopf!`](@ref)
constrains with `method=:cycles`, one KVL relation per entry.

A cycle closes back onto its first node, so its lines are the consecutive node
pairs plus the last-to-first pair. Controllable DC links are excluded, and a
radial AC network returns an empty vector.

Every AC interconnection must carry a `susceptance`; the call throws an
`ArgumentError` otherwise. It reads the topology only, so it may be called
before or after [`applydcopf!`](@ref), and on an extracted result.

See [`ptdfmatrix`](@ref) for the equivalent in the `:ptdf` formalism.
"""
function cyclebasis(s::Snapshot)
    mat, nodelist, _ = getic_susceptancematrix(s)
    return [nodelist[c] for c in gencycles(mat)]
end

# One KVL constraint per independent cycle: sum(flow_ij / B_ij) = 0.
function _applycycles!(s::Snapshot{T}, mat::Matrix{Float64}, nodelist::Vector{String},
                       node_map::Dict{String, Tuple{String, String}}, cycles) where T
    for c in cycles
        # initialize expression for this cycle: sum(flow_ij / B_ij) over all edges in cycle
        exp = Nosy.differentzerovector(T, Nosy.nsteps(s.sim))
        for i in eachindex(c)
            vi = c[i]
            # wrap around: last vertex connects back to first to close the cycle
            vj = (i < length(c)) ? c[i + 1] : c[1]
            from = nodelist[vi]
            to = nodelist[vj]
            bij = mat[vi, vj]
            bij >= 0.0 &&
                throw(AssertionError("No AC node IC between nodes $from and $to"))
            # KVL: sum(flow_ij / B_ij) = 0
            # flow_ij is net midpoint flow (forward - reverse) for bidirectional ICs
            # divide by susceptance B_ij to get voltage drop: V = flow / B
            add_to_expression!.(exp, (_net_ic_flow(s, from, to, node_map) / bij).data)
        end
        # enforce KVL constraint: sum of voltage drops around cycle must be zero
        @constraint(s.sim.model, exp .== 0.0)
    end
    return nothing
end
