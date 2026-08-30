"""
Loss post-processing.

Losses are collected once into a flat table so that they can be tracked down by
node, technology, component or category with plain DataFrame operations.
"""

using DataFrames: groupby, combine

"""
All loss categories reported by [`losses`](@ref).
"""
const LOSSCATEGORIES = (:node, :component, :interconnection, :storage, :selfdischarge)

"""
Loss categories that appear as flows in the nodal balance. The remaining ones
are internal to their component and are already embedded in its charging flow.
"""
const NETWORKLOSSES = (:node, :component, :interconnection)

# technology label of a loss source; node interconnections carry no `:tech` tag
# and are labelled by their AC/DC kind
function _lossestech(c::Component)
    t = get(c.tags, :tech, String[])
    isempty(t) || return first(t)
    hastag(c, :function, "DC") && return "DC"
    hastag(c, :function, "AC") && return "AC"
    return "unspecified"
end

# charging and self-discharge losses of a storage or EV component, as
# (category, value) pairs. Empty for any other component model.
function _storagelosses(c::Component, collapse::Bool)
    out = Tuple{Symbol,Any}[]
    eff, sd = if c.model isa Nosy.LazyStorageModel
        (get(c.model.data.eff, "input", 1.), c.model.data.self_discharge)
    elseif c.model isa Nosy.BasicStorageModel
        (c.model.data.eff_i, c.model.data.self_discharge)
    else
        # fixed-profile EVs are demand models: their optional grid-loss flow is
        # reported as a `:component` loss, and they store nothing
        return out
    end
    if !isone(eff) && Nosy.hasport(c, "input")
        v = balance(c, :input, energy, collapse=collapse, aggregate=false)["input"]
        push!(out, (:storage, v * (1. - eff)))
    end
    if !iszero(sd)
        push!(out, (:selfdischarge, _selfdischargeloss(c, sd, collapse)))
    end
    return out
end

# Over a timestep of duration Δt the level equation retains (1 - sd)^Δt of the
# level the step starts from. The loss is therefore evaluated on the native step
# grid, which is also the only grid on which it matches the model exactly.
function _selfdischargeloss(c::Component, sd::Float64, collapse::Bool)
    m = Nosy.mesh(c)
    lev = parent(Nosy._balance(c, :level, energy, collapse=false, aggregate=true))
    w = Float64.(parent(Nosy.weight(m)))
    steploss = lev .* (1. .- (1. - sd) .^ w)
    collapse && return sum(steploss)
    return _spreadoverhours(steploss, w, m)
end

# Spread per-step quantities over the hours each step covers, so that the hourly
# series still sums to the step total. Steps and hours coincide on a unit mesh.
function _spreadoverhours(v::Vector{Float64}, w::Vector{Float64}, m::TimeMesh)
    Nosy.isunit(m) && return v
    out = zeros(Nosy.nhours(m))
    t = 0. # hours elapsed at the start of the current step
    for i in eachindex(v)
        left = w[i]
        while left > 1e-9
            h = min(floor(Int, t) + 1, length(out))
            take = min(left, h - t)
            take <= 0 && break
            out[h] += v[i] * take / w[i]
            t += take
            left -= take
        end
    end
    return out
end

"""
    losses(s::Snapshot; collapse=true, categories=LOSSCATEGORIES, by=nothing)

Return a `DataFrame` of the electricity losses of Snapshot `s`, with one row per
(loss source, node) pair and the columns:

| column     | content                                                          |
|:-----------|:-----------------------------------------------------------------|
| `node`     | electricity node the loss is charged to                          |
| `source`   | component causing the loss, or the node name for `:node` losses  |
| `tech`     | technology label of the source                                   |
| `category` | one of `$(LOSSCATEGORIES)`                                       |
| `losses`   | MWhe value, or hourly MWhe series when `collapse=false`          |

Lossless sources are omitted, so an empty table means a lossless system.

`categories` restricts the reported categories:

  * `:node`: nodal losses of `Node(losses=...)`, a ratio of the node inflow
  * `:component`: proportional `grid losses` flow of a single component
  * `:interconnection`: transfer losses of a node interconnection
  * `:storage`: charging conversion loss of a storage or EV, `input * (1 - eff)`
  * `:selfdischarge`: stored energy lost over a timestep

Only `$(NETWORKLOSSES)` are flows of the nodal balance; `:storage` and
`:selfdischarge` are internal to their component and are already included in
its charging flow.

Every row is attributed to a single node, and a component spanning several
electricity nodes (a node interconnection) splits its loss equally between
them. Therefore `sum(df.losses)` is the system total, grouping by `node` gives
nodal losses and grouping by `source` gives whole-component losses.

`by` aggregates the table over one or more of `:node`, `:source`, `:tech` and
`:category`, keeping the `losses` column:

```julia
losses(result)                          # every loss source
losses(result; by=:node)                # losses of each node
losses(result; by=(:tech, :category))   # losses of each technology, split by cause
losses(result; by=:source, categories=(:interconnection,))  # losses of each interconnection
```

Losses of non-electricity nodes (e.g. hydrogen storage) are out of scope, and
so are carrier conversion losses (electrolysis, fuel to power): their output is
a product on another carrier rather than a loss of the electricity system.
"""
function losses(s::Snapshot; collapse::Bool=true, categories=LOSSCATEGORIES, by=nothing)
    df = _losstable(s, collapse, categories)
    isnothing(by) && return df
    cols = by isa Symbol ? [by] : collect(by)
    @argcheck !isempty(cols) "`by` needs at least one column"
    isempty(df) && return df[!, [cols..., :losses]]
    # `Ref` keeps an hourly series a single value instead of expanding to rows
    return combine(groupby(df, cols), :losses => (v -> Ref(sum(v))) => :losses)
end

# flat loss table, one row per (loss source, node) pair
function _losstable(s::Snapshot, collapse::Bool, categories)
    node = String[]; source = String[]; tech = String[]; category = Symbol[]
    val = (collapse ? Float64 : Vector{Float64})[]
    function _push!(n, src, t, cat, v)
        # a lossless source is not a loss: node interconnections always carry a
        # `grid losses ic` port, even with `loss_factor=0`
        (cat in categories && !all(iszero, v)) || return
        push!(node, n); push!(source, src); push!(tech, t); push!(category, cat); push!(val, v)
    end

    enodes = getnodes(s, with=[:electricity])

    # losses modelled by Nosy on the node itself, as a ratio of the node inflow.
    # Read from the inflow rather than from the node loss port, which Nosy keys
    # by node name in the output balance.
    for (nname, n) in enodes
        iszero(n.losses) && continue
        inflow = balance(n, :input, energy, collapse=collapse, aggregate=true)
        _push!(nname, nname, "network", :node, inflow * n.losses)
    end

    # component losses, shared equally between the electricity nodes they connect
    hosts = LittleDict{String,Vector{String}}()
    for (nname, _) in enodes, (cname, _) in getcomponents(s, nname)
        push!(get!(hosts, cname, String[]), nname)
    end
    for (cname, nnames) in hosts
        c = Nosy.getcomponent(s, cname)
        t = _lossestech(c)
        share = 1 / length(nnames)
        entries = Tuple{Symbol,Any}[]
        for (port, cat) in (("grid losses", :component), ("grid losses ic", :interconnection))
            (cat in categories && Nosy.hasport(c, port)) || continue
            sense = Nosy.portsense(c.s, Nosy.PortRef(cname, port))
            push!(entries, (cat, balance(c, sense, energy, collapse=collapse, aggregate=false)[port]))
        end
        if :storage in categories || :selfdischarge in categories
            append!(entries, _storagelosses(c, collapse))
        end
        for (cat, v) in entries, nname in nnames
            _push!(nname, cname, t, cat, v * share)
        end
    end

    return DataFrame(node=node, source=source, tech=tech, category=category, losses=val)
end

# Report label of a loss category. The network categories are shown as variants
# of one grid loss, because together they are the "Grid losses" column of the
# annual tables. Symbols stay plain identifiers so that `categories` filters and
# `category` comparisons remain writable.
_losslabel(cat::Symbol) = cat in NETWORKLOSSES ? "grid ($cat)" : string(cat)

# pivot the loss table as one row per node and one column per value of `key`
function _dataline_losses_pivot(df::DataFrame, key::Symbol, title::String; label=string)
    nodes = unique(df.node)
    labels = sort(unique(label.(df[!, key])))
    out = DataFrame("zone" => nodes)
    for l in labels
        mask = label.(df[!, key]) .== l
        out[!, l] = [sum(df.losses[mask .& (df.node .== n)], init=0.) / 1E6 for n in nodes]
    end
    # `reduce` with `init` so that a single label column is copied, not aliased
    ncol(out) > 1 && (out[!, "Total"] = reduce(+, eachcol(out)[2:end], init=zeros(nrow(out))))
    isempty(nodes) || push!(out, permutedims(vcat("Total", [sum(c) for c in eachcol(out)[2:end]])))
    return DataLine(title, "TWh/y", out)
end

"""
    genlosses(s::Snapshot)
Return the loss report of Snapshot `s`: losses per node broken down by category,
then by technology, then the detailed per-source table.
"""
function genlosses(s::Snapshot)
    df = losses(s)
    detail = DataFrame(
        "zone" => df.node,
        "source" => df.source,
        "technology" => df.tech,
        "category" => _losslabel.(df.category),
        "losses" => df.losses / 1E6,
    )
    return [
        _dataline_losses_pivot(df, :category, "Losses by category"; label=_losslabel),
        _dataline_losses_pivot(df, :tech, "Losses by technology"),
        DataLine("Detailed losses", "TWh/y", detail),
    ]
end
