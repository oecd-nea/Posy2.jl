# return the price of an price interconnection component
function geticprice(c::Component)
    hastag(c, :function, "priceinterconnection") || throw(ArgumentError("expected :function=>\"priceinterconnection\" on $(c.name)"))
    _price_import = zeros(Nosy.nhours(sim(c)))
    _price_export = zeros(Nosy.nhours(sim(c)))
    for b in Nosy.getbehaviors(c, Nosy.VariableCostBehavior)
        if b.data.pname == "output"
            _price_import .+= b.data.val
        elseif b.data.pname == "input"
            _price_export .+= b.data.val
        end
    end
    return Dict(:import => _price_import, :export => -_price_export)
end

# return a Dict of series indicating whether the price interconnection is maxed
function ispriceicmaxed(c::Component)
    hastag(c, :function, "priceinterconnection") || throw(ArgumentError("expected :function=>\"priceinterconnection\" on $(c.name)"))
    cin = capacity(c, "input", multiplier=true)
    cout = capacity(c, "output", multiplier=true)
    bin = balance(c, :input, energy, collapse=false, aggregate=false)["input"]
    bout = balance(c, :output, energy, collapse=false, aggregate=false)["output"]
    d = Dict(
        :export => isapprox.(cin, bin; atol=1e-6, rtol=0),
        :import => isapprox.(cout, bout; atol=1e-6, rtol=0)
    )
    return d
end

# return a Dict of series indicating whether the node interconnection is maxed
function isnodeicmaxed(c::Component)
    hastag(c, :function, "nodeinterconnection") || throw(ArgumentError("expected :function=>\"nodeinterconnection\" on $(c.name)"))
    cin = capacity(c, "input", multiplier=true)
    cout = capacity(c, "input2", multiplier=true)
    bin = balance(c, :input, energy, collapse=false, aggregate=false)["input"]
    bout = balance(c, :input, energy, collapse=false, aggregate=false)["input2"]
    d = Dict(
        :input => isapprox.(cin, bin; atol=1e-6, rtol=0),
        :input2 => isapprox.(cout, bout; atol=1e-6, rtol=0)
    )
    return d
end

# evaluate self IC cost at self node price (snode must be pre-resolved)
function _selfinterconnectioncost(s::Snapshot, cname::String, sense::Symbol, snode::Node)
    # evaluating cost = volume * price
    # the price is defined as the SELF price! (not the other node price)
    vprice = Nosy.dualprice(snode) # Nosy.dualprice(nnode)
    # dualprice is nothing when nodal prices were not evaluated (e.g. evalprice=false)
    isnothing(vprice) && return missing
    if sense == :import
        vol = balance(snode, :input, energy, collapse=false, aggregate=false)[cname] # flow going in self node to IC component
    elseif sense == :export
        vol = balance(snode, :output, energy, collapse=false, aggregate=false)[cname] # flow going out of self node to IC component
    else
        throw(AssertionError("sense must be :import or :export"))
    end
    return sum(vprice .* vol)
end

"""
    _selfinterconnectioncost(s::Snapshot, cname::String, sense::Symbol, tag::String)
Return the "self" cost associated with interconnection named `cname`, for sense `sense` ∈ (:import, :export), with tag `tag`.
"""
function _selfinterconnectioncost(s::Snapshot, cname::String, sense::Symbol, tag::String)
    if tag == "nodeinterconnection"
        selfnodes_trade, _, _ = _node_ic_endpoints(s, cname)
        return _selfinterconnectioncost_from_selfnodes(s, cname, sense, selfnodes_trade)
    end
    # find self node connected to this interconnection component
    vsnode = Node[]
    for (_sname, _snode) in getnodes(s, with=[:electricity], without=[:foreign])
        if haskey(getcomponents(s, _sname, with=[:function => "interconnection", :function => tag]), cname)
            push!(vsnode, _snode)
        end
    end
    isempty(vsnode) && return 0. # interconnection between two foreign nodes
    length(vsnode) > 1 && throw(AssertionError("Found more than one self node for component $cname")) # likely: internal IC, not foreign
    return _selfinterconnectioncost(s, cname, sense, first(vsnode))
end

# return self, foreign nodes connected to node IC `cname`
function _node_ic_endpoints(s::Snapshot, cname::String)
    ic_tag = [:function => "interconnection", :function => "nodeinterconnection"]
    selfnodes_trade = Node[]
    selfnodes_rent = Node[]
    foreignnodes = Node[]
    # find self nodes connected to this interconnection component (electricity, for import/export)
    for (_sname, snode) in getnodes(s, with=[:electricity], without=[:foreign])
        if haskey(getcomponents(s, _sname, with=ic_tag), cname)
            push!(selfnodes_trade, snode)
        end
    end
    # find the matching self node (congestion rent)
    for (_sname, snode) in getnodes(s, without=[:foreign])
        if haskey(getcomponents(s, _sname, with=ic_tag), cname)
            push!(selfnodes_rent, snode)
        end
    end
    # find the matching neighbor node
    for (_nname, nnode) in getnodes(s, with=[:foreign])
        if haskey(getcomponents(s, _nname, with=ic_tag), cname)
            push!(foreignnodes, nnode)
        end
    end
    return (selfnodes_trade, selfnodes_rent, foreignnodes)
end

# return self interconnection cost from resolved self node list
function _selfinterconnectioncost_from_selfnodes(s::Snapshot, cname::String, sense::Symbol, selfnodes::AbstractVector{Node})
    isempty(selfnodes) && return 0. # interconnection between two foreign nodes
    length(selfnodes) > 1 && throw(AssertionError("Found more than one self node for component $cname")) # likely: internal IC, not foreign
    return _selfinterconnectioncost(s, cname, sense, first(selfnodes))
end

# return node IC congestion rent from resolved self/foreign node lists
function _selfcongestionrent_from_endpoints(s::Snapshot, cname::String, selfnodes::AbstractVector{Node}, foreignnodes::AbstractVector{Node})
    isempty(foreignnodes) && throw(AssertionError("Foreign node not found for component $cname"))
    length(foreignnodes) > 1 && return 0. # two foreign nodes
    isempty(selfnodes) && throw(AssertionError("Self node not found for component $cname"))
    length(selfnodes) > 1 && throw(AssertionError("Found more than one self node for component $cname"))
    return _selfcongestionrent_node(s, cname, first(selfnodes), first(foreignnodes))
end

selfinterconnectioncost_node(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :import, "nodeinterconnection")
selfinterconnectionrevenue_node(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :export, "nodeinterconnection")
selfinterconnectioncost_price(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :import, "priceinterconnection")
selfinterconnectionrevenue_price(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :export, "priceinterconnection")

# congestion rent at pre-resolved self and neighbor nodes
function _selfcongestionrent_node(s::Snapshot, cname::String, snode::Node, nnode::Node)
    # price difference
    ps = Nosy.dualprice(snode)
    pn = Nosy.dualprice(nnode)
    # dualprice is nothing when nodal prices were not evaluated (e.g. evalprice=false)
    (isnothing(ps) || isnothing(pn)) && return missing
    pricediff = ps - pn

    # can't use capacity because it can be asymmetric
    # bidirectional flow
    vol = balance(snode, :output, energy, collapse=false, aggregate=false)[cname] + balance(nnode, :output, energy, collapse=false, aggregate=false)[cname]

    # is interconnector maxed
    # this is useful because IC may be associated with a transaction cost => price may be different even with non-saturated IC
    dmaxed = isnodeicmaxed(Nosy.getcomponent(s, cname))
    return 1/2 * sum(abs.((dmaxed[:input] + dmaxed[:input2]) .* vol .* pricediff))
end

"""
    selfcongestionrent_node(s::Snapshot, cname::String)
Return the congestion rent of an node-based interconnection (between nodes).
"""
function selfcongestionrent_node(s::Snapshot, cname::String)
    _, selfnodes_rent, foreignnodes = _node_ic_endpoints(s, cname)
    return _selfcongestionrent_from_endpoints(s, cname, selfnodes_rent, foreignnodes)
end

# congestion rent at pre-resolved local node
function _selfcongestionrent_price(s::Snapshot, cname::String, node::Node)
    c = Nosy.getcomponent(s, cname)

    # price difference
    # NB due to marginal cost, there remains a price difference at all times, together with a non-maxed interconnection
    dprice = geticprice(c)
    dmaxed = ispriceicmaxed(c)
    dcap = Dict(
        :import => capacity(c, "output", multiplier=true),
        :export => capacity(c, "input", multiplier=true),
    )
    nodeprice = Nosy.dualprice(node)
    # dualprice is nothing when nodal prices were not evaluated (e.g. evalprice=false)
    isnothing(nodeprice) && return missing
    return 1/2 * (sum(abs.(dmaxed[:import] .* dcap[:import] .* (dprice[:import] - nodeprice))) + sum(abs.(dmaxed[:export] .* dcap[:export] .* (dprice[:export] - nodeprice))))
end

"""
    selfcongestionrent_price(s::Snapshot, cname::String)
Return the congestion rent of an price-based interconnection (using exogenous price time series).
"""
function selfcongestionrent_price(s::Snapshot, cname::String)
    # find the local electricity node connected to this price IC
    node = nothing
    for (nodename, _nnode) in getnodes(s, with=[:electricity])
        if haskey(getcomponents(s, nodename, with=[:function => "interconnection", :function => "priceinterconnection"]), cname)
            node = _nnode
            break
        end
    end
    node === nothing && throw(AssertionError("Node not found for component $cname"))
    return _selfcongestionrent_price(s, cname, node)
end

# remove rows populated only with zeros (except on first column)
function _removezerorows!(df::DataFrame)
    filter!(row -> !all(iszero(v) for v in row[2:end]), df)
end

"""
    selfcosts(s::Snapshot; addtotal=true)
Evaluate the costs associated with the "self" nodes (not foreign). In particular:
  * only add the costs of components associated with self nodes
  * re-evaluate imports and exports costs, based on self price (both for node-based interconnections and price-based interconnections)
  * evaluate congestion rent
"""
function selfcosts(s::Snapshot; removezero::Bool=false, addtotal::Bool=true)
    df = costs(s, removezero=false, addtotal=false)
   
    # remove components associated to foreign nodes only
    _vselfcompname = String[]
    for (nname, _) in getnodes(s, with=[:electricity], without=[:foreign])
        for (cname, _) in getcomponents(s, nname)
            !(cname in _vselfcompname) && push!(_vselfcompname, cname)
        end
    end
    for cname in reverse(df[!,:component]) # iterate reversely because we're modifying the dataframe as we iterate it
        !(cname in _vselfcompname) && deleteat!(df, df[!,:component] .== cname)
    end

    # add "congestion rent" column (allow missing when dualprice is unavailable)
    df[!,"congestion rent"] = Vector{Union{Missing,Float64}}(zeros(nrow(df)))

    # check imports and exports columns are already present
    if !("imports" in names(df))
        df[!,"imports"] = zeros(nrow(df))
    end
    if !("exports" in names(df))
        df[!,"exports"] = zeros(nrow(df))
    end
    df[!,"imports"] = Vector{Union{Missing,Float64}}(df[!,"imports"])
    df[!,"exports"] = Vector{Union{Missing,Float64}}(df[!,"exports"])

    # iterate on node-based IC with neighbors
    # outer loop on foreign nodes, inner loop on components
    for (nname, _) in getnodes(s, with=[:electricity, :foreign])
        d = getcomponents(s, nname, with=[:function => "interconnection", :function => "nodeinterconnection"])
        for (cname, _) in d
            mask = df[!, :component] .== cname
            any(mask) || continue
            selfnodes_trade, selfnodes_rent, foreignnodes = _node_ic_endpoints(s, cname)
            df[mask, :imports] .= _selfinterconnectioncost_from_selfnodes(s, cname, :import, selfnodes_trade)
            df[mask, :exports] .= -_selfinterconnectioncost_from_selfnodes(s, cname, :export, selfnodes_trade)
            df[mask, Symbol("congestion rent")] .= -_selfcongestionrent_from_endpoints(s, cname, selfnodes_rent, foreignnodes)
        end
    end

    # iterate on price series IC
    # outer loop on self nodes, inner loop on components
    for (nname, snode) in getnodes(s, with=[:electricity], without=[:foreign])
        d = getcomponents(s, nname, with=[:function => "interconnection", :function => "priceinterconnection"])
        for (cname, _) in d
            df[df[!,:component] .== cname, :imports] .= _selfinterconnectioncost(s, cname, :import, snode)
            df[df[!,:component] .== cname, :exports] .= -_selfinterconnectioncost(s, cname, :export, snode)
            df[df[!,:component] .== cname, Symbol("congestion rent")] .= -_selfcongestionrent_price(s, cname, snode)
        end
    end

    # add totals (missing propagates when a self-price revaluation was unavailable)
    if addtotal
        push!(df, LittleDict(:component => "all", (Symbol(cname) => sum(df[!,cname]) for cname in names(df)[2:end])...))
        df[!,:total] = sum(c for c in eachcol(df)[2:end])
    end

    # remove zeros
    if removezero
        _removezerorows!(df)
    end

    return df
end

"""
    selfcost(s::Snapshot)
Return the self total cost associated with Snapshot `s`. This includes:
  * all non-interconnection components in `self` nodes
  * no non-interconnection components in `foreign` nodes
  * import costs and export revenues for interconnections connected to `self` nodes
  * congestion rent for interconnections connected to `self` nodes
"""
function selfcost(s::Snapshot)
    df = selfcosts(s, addtotal=true)
    return first(df[df[!,:component] .== "all","total"])
end