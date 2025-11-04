# return the price of an price interconnection component
function geticprice(c::Component)
    @assert hastag(c, :priceinterconnection)
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
    @assert hastag(c, :priceinterconnection)
    cin = capacity(c, "input", multiplier=true)
    cout = capacity(c, "output", multiplier=true)
    bin = balance(c, :input, energy, collapse=false, aggregate=false)["input"]
    bout = balance(c, :output, energy, collapse=false, aggregate=false)["output"]
    d = Dict(
        :export => isapprox.(cin, bin),
        :import => isapprox.(cout, bout)
    )
    return d
end

# return a Dict of series indicating whether the node interconnection is maxed
function isnodeicmaxed(c::Component)
    @assert hastag(c, :nodeinterconnection)
    cin = capacity(c, "input", multiplier=true)
    cout = capacity(c, "input2", multiplier=true)
    bin = balance(c, :input, energy, collapse=false, aggregate=false)["input"]
    bout = balance(c, :input, energy, collapse=false, aggregate=false)["input2"]
    d = Dict(
        :input => isapprox.(cin, bin),
        :input2 => isapprox.(cout, bout)
    )
    return d
end

"""
    _selfinterconnectioncost(s::Snapshot, cname::String, sense::Symbol, tag::Symbol)
Return the "self" cost associated with interconnection named `cname`, for sense `sense` ∈ (:import, :export), with tag `tag`.
"""
function _selfinterconnectioncost(s::Snapshot, cname::String, sense::Symbol, tag::Symbol)
    # find self node associated with IC component
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    vsnode = Node[]
    for (_sname, _snode) in selfnodes
        if contains(cname, _sname)
            push!(vsnode, _snode)
        end
    end
    isempty(vsnode) && return 0. # interconnection between two foreign nodes
    length(vsnode) > 1 && throw(AssertionError("Found more than one self node for component name $cname")) # likely: internal IC, not foreign
    snode = first(vsnode)

    # check component is connected to node snode
    @assert haskey(getcomponents(s, snode.name, with=[tag]), cname)

    # evaluating cost = volume * price
    # the price is defined as the SELF price! (not the other node price)
    vprice = Nosy.dualprice(snode) # Nosy.dualprice(nnode)
    if sense == :import
        vol = balance(snode, :input, energy, collapse=false, aggregate=false)[cname] # flow going in self node to IC component
    elseif sense == :export
        vol = balance(snode, :output, energy, collapse=false, aggregate=false)[cname] # flow going out of self node to IC component
    else
        throw(AssertionError("sense must be :import or :export"))
    end
    _cost = sum(vprice .* vol)
    return _cost
end

selfinterconnectioncost_node(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :import, :nodeinterconnection)
selfinterconnectionrevenue_node(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :export, :nodeinterconnection)
selfinterconnectioncost_price(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :import, :priceinterconnection)
selfinterconnectionrevenue_price(s::Snapshot, cname::String) = _selfinterconnectioncost(s, cname, :export, :priceinterconnection)

"""
    selfcongestionrent_node(s::Snapshot, cname::String)
Return the congestion rent of an node-based interconnection (between nodes).
"""
function selfcongestionrent_node(s::Snapshot, cname::String)
    # find the matching neighbor node
    neighbornodes = getnodes(s, with=[:foreign])
    local vnnode = Node[]
    for (_nname, _nnode) in neighbornodes
        if contains(cname, _nname)
            push!(vnnode, _nnode)
        end
    end
    isempty(vnnode) && throw(AssertionError("Foreign node not found for component name $cname"))
    length(vnnode) > 1 && return 0. # two foreign nodes
    nnode = first(vnnode)

    # find the matching self node
    selfnodes = getnodes(s, without=[:foreign])
    local vnnode = Node[]
    for (_nname, _nnode) in selfnodes
        if contains(cname, _nname)
            push!(vnnode, _nnode)
        end
    end
    isempty(vnnode) && throw(AssertionError("Self node not found for component name $cname"))
    length(vnnode) > 1 && throw(AssertionError("Found more than one self node for component name $cname"))
    snode = first(vnnode)

    # check component is an explicit IC from nodes nnode and snode
    @assert haskey(getcomponents(s, snode.name, with=[:interconnection, :nodeinterconnection]), cname)
    @assert haskey(getcomponents(s, nnode.name, with=[:interconnection, :nodeinterconnection]), cname)

    # price difference
    pricediff = Nosy.dualprice(snode) - Nosy.dualprice(nnode)

    # can't use capacity because it can be asymmetric
    # bidirectional flow
    vol = balance(snode, :output, energy, collapse=false, aggregate=false)[cname] + balance(nnode, :output, energy, collapse=false, aggregate=false)[cname]

    # is interconnector maxed
    # this is useful because IC may be associated with a transaction cost => price may be different even with non-saturated IC
    dmaxed = isnodeicmaxed(Nosy.getcomponent(s, cname))

    cr = 1/2 * sum(abs.((dmaxed[:input] + dmaxed[:input2]) .* vol .* pricediff))

    return cr
end

"""
    selfcongestionrent_price(s::Snapshot, cname::String)
Return the congestion rent of an price-based interconnection (using exogenous price time series).
"""
function selfcongestionrent_price(s::Snapshot, cname::String)
    # find the node it is connected to
    nodes = getnodes(s, with=[:electricity])
    local vnnode = Node[]
    for (_nname, _nnode) in nodes
        if contains(cname, _nname)
            push!(vnnode, _nnode)
        end
    end
    isempty(vnnode) && throw(AssertionError("Node not found for component name $cname"))
    length(vnnode) > 1 && throw(AssertionError("Found more than one node for component name $cname"))
    node = first(vnnode)

    # check component is an explicit IC from node 
    @assert haskey(getcomponents(s, node.name, with=[:interconnection, :priceinterconnection]), cname)
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

    cr = 1/2 * (sum(abs.(dmaxed[:import] .* dcap[:import] .* (dprice[:import] - nodeprice))) + sum(abs.(dmaxed[:export] .* dcap[:export] .* (dprice[:export] - nodeprice))))
    return cr
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

    # add "congestion rent" column
    df[!,"congestion rent"] = zeros(nrow(df))

    # check imports and exports columns are already present
    if !("imports" in names(df))
        df[!,"imports"] = zeros(nrow(df))
    end
    if !("exports" in names(df))
        df[!,"exports"] = zeros(nrow(df))
    end
    
    # iterate on node-based IC with neighbors
    # outer loop on foreign nodes, inner loop on components
    for (nname, _) in getnodes(s, with=[:electricity, :foreign])
        d = getcomponents(s, nname, with=[:interconnection, :nodeinterconnection])
        for (cname, _) in d
            df[df[!,:component] .== cname, :imports] .= selfinterconnectioncost_node(s, cname)
            df[df[!,:component] .== cname, :exports] .= -selfinterconnectionrevenue_node(s, cname)
            df[df[!,:component] .== cname, Symbol("congestion rent")] .= -selfcongestionrent_node(s, cname)
        end
    end

    # iterate on price series IC
    # outer loop on self nodes, inner loop on components
    for (nname, _) in getnodes(s, with=[:electricity], without=[:foreign])
        d = getcomponents(s, nname, with=[:interconnection, :priceinterconnection])
        for (cname, _) in d

            # throw(AssertionError("TODO: re-evaluate import / export cost on price IC (export / import at self price)"))

            df[df[!,:component] .== cname, :imports] .= selfinterconnectioncost_price(s, cname)
            df[df[!,:component] .== cname, :exports] .= -selfinterconnectionrevenue_price(s, cname)
            df[df[!,:component] .== cname, Symbol("congestion rent")] .= -selfcongestionrent_price(s, cname)
        end
    end

    # add totals
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