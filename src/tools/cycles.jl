"""
Analyze cycles in the interconnection graph.
Goal: Kirchhoff voltage law (DC power flow).
"""

using Graphs: SimpleGraph, cycle_basis, add_edge!
using JuMP: @constraint

# Build B-matrix (susceptance matrix) from AC node interconnections only.
# DC interconnections are excluded because KVL does not apply to DC circuits.
# Susceptance values come from `Snapshot.options[:ic_susceptance]` (registered by
# `makenodeinterco`), not from component tags or name parsing.
function getic_susceptancematrix(s::Snapshot)
    nodelist = sort(collect(keys(getnodes(s, with=[:electricity]))))
    nodeindex = Dict(n => i for (i, n) in enumerate(nodelist))
    N = length(nodelist)
    mat = zeros(Float64, N, N)
    # cache node connections to avoid repeated topology lookups
    node_map = Dict{String, Tuple{String, String}}()  # cname => (from, to)

    for (cname, c) in getcomponents(s, with=[:function => "nodeinterconnection"], without=[:function => "DC"])
        from, to = _fromto_ic_internal(s, c)
        bij = ic_susceptance(s, from, to)
        i = nodeindex[from]
        j = nodeindex[to]
        # symmetric matrix (undirected graph)
        mat[i, j] = bij
        mat[j, i] = bij
        node_map[cname] = (from, to)
    end

    return mat, nodelist, node_map
end

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

# Return net midpoint power flow between two nodes (from -> to).
# Each directional midpoint flow is the average of its sending- and receiving-end
# flows, so half of the proportional interconnection loss is applied in KVL.
# `node_map` is AC-only (DC excluded from KVL). Nets on the same pair are summed.
# Parallel AC is rejected at build, so usually one IC matches.
function _net_ic_flow(s::Snapshot, from::String, to::String, node_map::Dict{String, Tuple{String, String}})
    net = nothing
    for (cname, (ic_from, ic_to)) in node_map
        (ic_from, ic_to) == (from, to) || (ic_from, ic_to) == (to, from) || continue
        c = Nosy.getcomponent(s, cname)
        inputs = balance(c, :input, energy, collapse=false, aggregate=false)
        outputs = balance(c, :output, energy, collapse=false, aggregate=false)
        fwd = (inputs["input"] + outputs["output"]) / 2
        rev = (inputs["input2"] + outputs["output2"]) / 2
        # determine IC orientation to compute net flow correctly
        flow = (ic_from == from && ic_to == to) ? (fwd - rev) : (rev - fwd)
        net = isnothing(net) ? flow : (net .+ flow)
    end
    isnothing(net) && throw(AssertionError("No AC node IC between $from and $to"))
    return net
end

# Put KVL at snapshot level so cycles are enforced globally.
# For each cycle in the AC network, apply KVL constraint: sum(flow_ij / B_ij) = 0.
# Called from `applydcopf!` when `Posy2Options.dcopf` is true. Applies once per
# snapshot: `Snapshot.options[:kvl_applied]` marks the topology as frozen.
function addkvl!(s::Snapshot{T}) where T
    haskey(s.options, :kvl_applied) && throw(ArgumentError(
        "KVL constraints have already been applied to this snapshot; applydcopf! must be called exactly once, after the full node interconnection topology is built",
    ))
    # build B-matrix (susceptance matrix) from AC node ICs only
    mat, nodelist, node_map = getic_susceptancematrix(s)
    cycles = gencycles(mat)
    # marker set once the topology has been read: it freezes the node ICs and
    # blocks a second application, which would stack duplicate constraints.
    s.options[:kvl_applied] = true
    if isempty(node_map) || isempty(cycles)
        @warn "No AC loops were found. no KVL constraints were added."
        return nothing
    end

    # find minimal set of independent cycles using cycle basis
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
