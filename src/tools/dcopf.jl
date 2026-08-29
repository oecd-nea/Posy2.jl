"""
DC power flow (Kirchhoff voltage law) on the AC interconnection graph.

Two equivalent formalisms are available, selected by `applydcopf!(s; method=...)`:
cycle voltage drops (`:cycles`, see `cycles.jl`) and power transfer distribution
factors (`:ptdf`, see `ptdf.jl`).
"""

const DCOPF_METHODS = (:cycles, :ptdf)

# Build B-matrix (susceptance matrix) from AC node interconnections only.
# DC interconnections are excluded because KVL does not apply to DC circuits.
# Susceptance values come from `Snapshot.options[:ic_susceptance]` (registered by
# `makenodeinterco`), not from component tags or name parsing.
function getic_susceptancematrix(s::Snapshot)
    nodelist = sort!(collect(String, keys(getnodes(s, with=[:electricity]))))
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

"""
    applydcopf!(s::Snapshot; method::Symbol=:cycles)

Add DC power flow (KVL) constraints at snapshot level, so that the AC network
physics is enforced globally. Flows are the net midpoint flows of the AC node
interconnections, and `B_ij` the susceptance registered by
[`makenodeinterco`](@ref). DC interconnections are excluded. Warns when there is
no AC loop to constrain.

`method` selects the formalism, which describe the same physics and give the
same flows:

- `:cycles` (default) writes one constraint per independent AC cycle `C`,
  `sum_{(i,j) in C} flow_ij / B_ij = 0`: the voltage drops around a loop cancel.
- `:ptdf` writes one constraint per AC line, `flow_l = sum_n PTDF[l,n] * p_n`,
  where `p_n` is the net AC injection at node `n` and `PTDF` the power transfer
  distribution factor matrix of the AC network.

Call it before `Nosy.optimize!` in the studies that need DC power flow, and
leave it out of the others: there is no snapshot option to switch it off.

It may be called only once per snapshot, and no node interconnection may be
added afterwards: the constraints are built from the topology present at the
call, so a second call would stack duplicates and a later interconnection would
leave them describing a different network. Both raise an `ArgumentError`.
"""
function applydcopf!(s::Snapshot; method::Symbol=:cycles)
    method in DCOPF_METHODS ||
        throw(ArgumentError("method must be one of $DCOPF_METHODS, got $(repr(method))"))
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
        # a radial AC network is fully determined by the nodal balances: both
        # formalisms would only add constraints that are already satisfied
        @warn "No AC loops were found. no KVL constraints were added."
        return nothing
    end

    if method === :cycles
        _applycycles!(s, mat, nodelist, node_map, cycles)
    else
        _applyptdf!(s, mat, nodelist, node_map)
    end
    return nothing
end
