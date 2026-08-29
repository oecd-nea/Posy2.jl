"""
PTDF formalism for DC power flow: line flows tied to the net nodal injections.
"""

using LinearAlgebra: pinv

# AC links as (from index, to index) into `nodelist`, ordered by interconnection
# name so that the constraint order is reproducible.
function _acbranches(nodelist::Vector{String}, node_map::Dict{String, Tuple{String, String}})
    nodeindex = Dict(n => i for (i, n) in enumerate(nodelist))
    return [(nodeindex[from], nodeindex[to]) for (_, (from, to)) in sort!(collect(node_map), by=first)]
end

"""
    ptdfmatrix(s::Snapshot)

Return the power transfer distribution factors of the snapshot's AC network as
a named tuple `(matrix, lines, nodes)`. This is the matrix
[`applydcopf!`](@ref) uses with `method=:ptdf`.

`matrix[l, n]` is the share of an injection at `nodes[n]` that flows through
`lines[l]`, counted positive in the direction of that line. `nodes` labels the
columns with the `:electricity` node names, sorted; `lines` labels the rows
with the `(from, to)` node pair of each AC interconnection, sorted by
interconnection name. Controllable DC links are excluded, so a node they alone
serve has an all-zero column.

The slack is distributed over the nodes, so every row sums to zero: a factor is
meaningful relative to the other factors of its row, not on its own. Subtract
column `k` to move to the usual convention of a single slack node `k`.

Every AC interconnection must carry a `susceptance`; the call throws an
`ArgumentError` otherwise. It reads the topology only, so it may be called
before or after [`applydcopf!`](@ref), and on an extracted result.

See [`cyclebasis`](@ref) for the equivalent of this matrix in the `:cycles`
formalism.
"""
function ptdfmatrix(s::Snapshot)
    mat, nodelist, node_map = getic_susceptancematrix(s)
    branches = _acbranches(nodelist, node_map)
    return (
        matrix=ptdfmatrix(mat, branches),
        lines=[(nodelist[i], nodelist[j]) for (i, j) in branches],
        nodes=nodelist,
    )
end

# Power transfer distribution factors of the AC network, as a
# `length(branches) x size(mat, 1)` matrix: row `l` gives the share of an
# injection at each node that flows through line `l`, oriented from its first
# node to its second. `mat` is the susceptance matrix and `branches` the
# `(from, to)` index pairs of the AC lines.
function ptdfmatrix(mat::Matrix{Float64}, branches)
    N = size(mat, 1)
    # incidence matrix A and line susceptances b = -B > 0, so that flow = b * (angle_i - angle_j)
    A = zeros(Float64, length(branches), N)
    b = zeros(Float64, length(branches))
    for (l, (i, j)) in enumerate(branches)
        A[l, i] = 1.0
        A[l, j] = -1.0
        b[l] = -mat[i, j]
    end
    bA = b .* A
    # PTDF = Bd * A * inv(A' * Bd * A). The nodal susceptance matrix is a
    # Laplacian, hence singular: the pseudo-inverse takes the place of the usual
    # slack-node reduction, and handles disconnected AC islands and nodes without
    # an AC line in the same step.
    return bA * pinv(A' * bA)
end

# One constraint per AC line: flow_l = sum_n PTDF[l, n] * p_n. The net injection
# p_n is taken as the AC flow leaving node n, which the nodal balance ties to the
# generation, demand and DC transfers at that node.
function _applyptdf!(s::Snapshot{T}, mat::Matrix{Float64}, nodelist::Vector{String},
                     node_map::Dict{String, Tuple{String, String}}) where T
    branches = _acbranches(nodelist, node_map)
    ptdf = ptdfmatrix(mat, branches)
    flows = [_net_ic_flow(s, nodelist[i], nodelist[j], node_map).data for (i, j) in branches]
    nsteps = length(first(flows))

    injections = [Nosy.differentzerovector(T, nsteps) for _ in nodelist]
    for (l, (i, j)) in enumerate(branches)
        add_to_expression!.(injections[i], flows[l])
        add_to_expression!.(injections[j], -1.0, flows[l])
    end

    for l in eachindex(branches)
        exp = Nosy.differentzerovector(T, nsteps)
        add_to_expression!.(exp, flows[l])
        for n in eachindex(nodelist)
            iszero(ptdf[l, n]) && continue
            add_to_expression!.(exp, -ptdf[l, n], injections[n])
        end
        @constraint(s.sim.model, exp .== 0.0)
    end
    return nothing
end
