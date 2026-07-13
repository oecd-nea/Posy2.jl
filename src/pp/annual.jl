using OrderedCollections: LittleDict
using Nosy: nhours
using Infiltrator


"""
    losses(s::Snapshot, compname::String; modifier=energy, collapse=true)
Return the time series associated with grid losses of `modifier` in component named `compname` of Snapshot `s`.
If `collapse`, return a value instead.
"""
function losses(s::Snapshot, compname::String; modifier=energy, collapse=true)
    c = s.components[compname]
    if Nosy.hasport(c, "grid losses")
        return balance(c, Nosy.portsense(c.s, Nosy.PortRef(compname, "grid losses")), modifier, collapse=collapse, aggregate=false)["grid losses"]
    elseif Nosy.hasport(c, "grid losses ic")
        return balance(c, Nosy.portsense(c.s, Nosy.PortRef(compname, "grid losses ic")), modifier, collapse=collapse, aggregate=false)["grid losses ic"] / 2 # avoiding double-counting; convention for interconnectors: half of loss for each connected node
    else
        if collapse
            return 0.
        else
            return zeros(Nosy.nhours(sim(s)))
        end
    end
end

"""
    production(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with production of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function production(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    if collapse
        ini = 0.
    else
        ini = zeros(nhours(sim(s)))
    end
    d = getcomponents(s, nodename, with=[:function => "generation"])
    val = sum([balance(v, :output, modifier, collapse=collapse, aggregate=false)["output"] for (k,v) in d], init=ini)
    return val  
end

"""
    charging(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with charging of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
For EVs, return the charging minus the driving consumption, resulting in the effective pure charging behavior (should be zero for non-V2G EVs).
"""
function charging(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    ds = getcomponents(s, nodename, with=[:function => "storage"])
    dev = getcomponents(s, nodename, with=[:function => "ev"])
    if collapse
        local c = 0.
    else
        local c = zeros(nhours(s.sim))
    end
    for (_,v) in ds
        b = balance(v, :input, modifier, collapse=collapse, aggregate=false)
        c += b["input"]
    end
    for (_,v) in dev
        bin = balance(v, :input, modifier, collapse=collapse, aggregate=false)
        bout = balance(v, :output, modifier, collapse=collapse, aggregate=false)
        c += (bin["input"] - bout["driving"])
    end
    return c
end

"""
    storageloss(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return the time series associated with storage charging losses of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a value instead.
"""
function storageloss(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = getcomponents(s, nodename, with=[:function => "storage", :function => "ev"])
    if collapse
        local c = 0.
    else
        local c = zeros(nhours(s.sim))
    end
    for (_,v) in d
        b = balance(v, :input, modifier, collapse=collapse, aggregate=false)
        if haskey(b, "input")
            if v.model isa Nosy.LazyStorageModel
                c += b["input"] * (1. - v.model.data.eff["input"])
            elseif v.model isa Nosy.BasicStorageModel
                c += b["input"] * (1. - v.model.data.eff_i)
            else
                @warn "Could not identify storage type"
            end
        end
    end
    return c
end

"""
    curtailment(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with curtailment of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function curtailment(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    n = Nosy.getnode(s, nodename)
    if n.rule == :curtailed
        bin = balance(Nosy.getnode(s, nodename), :input, modifier, collapse=collapse, aggregate=true)
        bout = balance(Nosy.getnode(s, nodename), :output, modifier, collapse=collapse, aggregate=true)
        return bin - bout
    else
        if collapse
            local cur = 0.
        else
            local cur = zeros(Nosy.nhours(sim(s)))
        end
        b = balance(Nosy.getnode(s, nodename), :output, modifier, collapse=collapse, aggregate=false)
        for (k,v) in b
            if k != "losses" && hastag(Nosy.getcomponent(s, k), :function, "curtailment")
                cur += v
            end
        end
        return cur
    end
end

"""
    demandresponse(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with demand response of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function demandresponse(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    if collapse
        ini = 0.
    else
        ini = zeros(nhours(sim(s)))
    end
    d = getcomponents(s, nodename, with=[:function => "demandresponse"])
    dem = sum([balance(v, :output, modifier, collapse=collapse, aggregate=true) for (k,v) in d], init=ini)
    return dem  
end

"""
    electrolysis(s::Snapshot, nodename::String; collapse=true)
Return a Dict of the time series associated with electrolysis in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function electrolysis(s::Snapshot, nodename::String; collapse=true)
    if collapse
        ini = 0.
    else
        ini = zeros(nhours(sim(s)))
    end
    d = getcomponents(s, nodename, with=[:function => "electrolysis"])
    dem = sum([balance(v, :input, energy, collapse=collapse, aggregate=false)["input"] for (k,v) in d], init=ini)
    return dem
end


struct DataLine{D}
    title::String
    unit::String
    d::D
end

# return a line with aggregated annual indicators e.g. demand, production etc.
function _dataline_demand_prod(s; showforeign=true)
    if showforeign
        enodes = getnodes(s, with=[:electricity])
    else
        enodes = getnodes(s, with=[:electricity], without=[:foreign])
    end
    
    d = LittleDict()
    d["zone"] = [k for (k,_) in enodes]
    d["Final consumption incl. electrolysis"] = [demand(s, k, aggregate=true, collapse=true)/1E6 for (k,_) in enodes]
    d["Production incl. discharging"] = [production(s, k)/1E6 for (k,_) in enodes] # includes discharging
    d["Charging"] = [charging(s, k)/1E6 for (k,_) in enodes]
    # d["Storage losses"] = [storageloss(s,k)/1E6 for (k,_) in enodes] # already counted in charging
    d["Grid losses"] = [sum([losses(s, cname)/1E6 for (cname, c) in getcomponents(s, k)], init=0.)  for (k,_) in enodes]
    # d["Electrolysis"] = [electrolysis(s,k)/1E6 for (k,_) in enodes] # already included in final consumption

    flows = _all_ic_directed_flows(s; collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    zone_keys = d["zone"]
    enode_set = Set(zone_keys)
    imp_all = Dict(k => LittleDict{String, Float64}() for k in zone_keys)
    exp_all = Dict(k => LittleDict{String, Float64}() for k in zone_keys)
    imp_int = Dict(k => LittleDict{String, Float64}() for k in zone_keys)
    exp_int = Dict(k => LittleDict{String, Float64}() for k in zone_keys)
    imp_for = Dict(k => LittleDict{String, Float64}() for k in zone_keys)
    exp_for = Dict(k => LittleDict{String, Float64}() for k in zone_keys)
    for ((from, to), flow) in flows
        if to in enode_set
            if from != to
                imp_all[to][from] = flow
                if haskey(selfnodes, from)
                    imp_int[to][from] = flow
                end
            end
            if !haskey(selfnodes, from)
                imp_for[to][from] = flow
            end
        end
        if from in enode_set
            if from != to
                exp_all[from][to] = flow
                if haskey(selfnodes, to)
                    exp_int[from][to] = flow
                end
            end
            if !haskey(selfnodes, to)
                exp_for[from][to] = flow
            end
        end
    end
    _ic_vol_sum(partners) = sum(values(partners), init=0.0) / 1E6
    if showforeign
        d["Imports"] = [_ic_vol_sum(imp_all[k]) for k in zone_keys]
        d["Exports"] = [_ic_vol_sum(exp_all[k]) for k in zone_keys]
    else
        d["Imports (internal)"] = [_ic_vol_sum(imp_int[k]) for k in zone_keys]
        d["Exports (internal)"] = [_ic_vol_sum(exp_int[k]) for k in zone_keys]
        d["Imports (foreign)"] = [_ic_vol_sum(imp_for[k]) for k in zone_keys]
        d["Exports (foreign)"] = [_ic_vol_sum(exp_for[k]) for k in zone_keys]
    end
    d["Demand response"] = [demandresponse(s,k)/1E6 for (k,_) in enodes]
    d["Curtailment"] = [curtailment(s,k)/1E6 for(k,_) in enodes]

    df = DataFrame(d)

    # sum over zones
    _lastrow = permutedims(vcat("Total", [sum(c) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)

    return DataLine(
        "Demand and production",
        "TWh/y",
        df
    )
end

# return a DataLine for capacity with specified parameters
function __dataline_cap(s::Snapshot, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Pair{Symbol,String}}, compswithout::Vector{Pair{Symbol,String}}, portname::String, title::String, unit::String, coeff=1E3)
    allcomps = String[]
    allnodes = getnodes(s, with=nodeswith, without=nodeswithout)
    allnode_comps = Dict(nodename => getcomponents(s, nodename, with=compswith, without=compswithout) for (nodename, _) in allnodes)
    for (_, d) in allnode_comps
        # list components connected to this zone (tech tag values, as in Excel sheet)
        for (_, comp) in d
            cname = only(get(comp.tags, :tech, String[]))
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)
    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])
    for (nodename,_) in allnodes
        v = Any[nodename]
        d = allnode_comps[nodename]
        compbytech = Dict(only(get(comp.tags, :tech, String[])) => comp for (_, comp) in d)
        for cname in allcomps
            comp = get(compbytech, cname, nothing)
            if comp === nothing
                push!(v, 0.)
            elseif Nosy.hasport(comp, portname)
                cap = capacity(comp, portname)
                push!(v, isnothing(cap) ? Inf : cap / coeff)
            else
                push!(v, 0.)
            end
        end
        push!(df, permutedims(v))
    end

    # sum over zones and components
    _lastrow = permutedims(vcat("Total", [sum(c) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)
    (ncol(df) > 1) && (df[!,"Total"] = sum(eachcol(df)[2:end]))

    return DataLine(
        title,
        unit,
        df
    )
end

function _dataline_elec_prod_cap(s; showforeign=true)
    if showforeign
        __dataline_cap(s, [:electricity], Symbol[], [:function => "generation"], Pair{Symbol,String}[], "output", "Electrical production capacity", "GWe")
    else
        __dataline_cap(s, [:electricity], [:foreign], [:function => "generation"], Pair{Symbol,String}[], "output", "Electrical production capacity", "GWe")
    end
end


function _merge_annual_df(df1, df2)
    df = leftjoin(df1, df2, on="zone", makeunique=true)
    if "Total_1" in names(df)
        total = df[!,:Total] + df[!,:Total_1]
        select!(df, Not([:Total, :Total_1]))
        df[!,"Total"] = total
    end
    return df
end

function _dataline_elec_storage_cap(s; showforeign=true) 
    if showforeign
        d1 = __dataline_cap(s, [:electricity], Symbol[], [:function => "storage"], Pair{Symbol,String}[], "input", "Electrical storage charging capacity", "GWe")
        d2 = __dataline_cap(s, [:electricity], Symbol[], [:function => "ev"], Pair{Symbol,String}[], "input", "Electrical storage charging capacity", "GWe")
    else
        d1 = __dataline_cap(s, [:electricity], [:foreign], [:function => "storage"], Pair{Symbol,String}[], "input", "Electrical storage charging capacity", "GWe")
        d2 = __dataline_cap(s, [:electricity], [:foreign], [:function => "ev"], Pair{Symbol,String}[], "input", "Electrical storage charging capacity", "GWe")
    end
    # merge DataLines
    df = _merge_annual_df(d1.d, d2.d)
    d = DataLine(
        "Electrical storage charging capacity",
        "GWe",
        df
    )
end

function _dataline_elec_storage_discharge_cap(s; showforeign=true)
    if showforeign
        d1 = __dataline_cap(s, [:electricity], Symbol[], [:function => "storage"], Pair{Symbol,String}[], "output", "Electrical storage discharging capacity", "GWe")
        d2 = __dataline_cap(s, [:electricity], Symbol[], [:function => "ev"], Pair{Symbol,String}[], "output", "Electrical storage discharging capacity", "GWe")
    else
        d1 = __dataline_cap(s, [:electricity], [:foreign], [:function => "storage"], Pair{Symbol,String}[], "output", "Electrical storage discharging capacity", "GWe")
        d2 = __dataline_cap(s, [:electricity], [:foreign], [:function => "ev"], Pair{Symbol,String}[], "output", "Electrical storage discharging capacity", "GWe")
    end
    df = _merge_annual_df(d1.d, d2.d)
    d = DataLine(
        "Electrical storage discharging capacity",
        "GWe",
        df
    )
end

function _dataline_elec_storage_cap_level(s; showforeign=true) 
    if showforeign
        d1 = __dataline_cap(s, [:electricity], Symbol[], [:function => "storage"], Pair{Symbol,String}[], "level", "Electrical storage max level", "TWhe", 1E6)
        d2 = __dataline_cap(s, [:electricity], Symbol[], [:function => "ev"], Pair{Symbol,String}[], "level", "Electrical storage max level", "TWhe", 1E6)
    else
        d1 = __dataline_cap(s, [:electricity], [:foreign], [:function => "storage"], Pair{Symbol,String}[], "level", "Electrical storage max level", "TWhe", 1E6)
        d2 = __dataline_cap(s, [:electricity], [:foreign], [:function => "ev"], Pair{Symbol,String}[], "level", "Electrical storage max level", "TWhe", 1E6)
    end
    # merge DataLines
    df = _merge_annual_df(d1.d, d2.d)
    d = DataLine(
        "Electrical storage max level",
        "TWhe",
        df
    )
end

function _dataline_electrolysis_cap(s; showforeign=true) 
    if showforeign
        __dataline_cap(s, [:electricity], Symbol[], [:function => "electrolysis"], Pair{Symbol,String}[], "input", "Electrolysis capacity", "GWe")
    else
        __dataline_cap(s, [:electricity], [:foreign], [:function => "electrolysis"], Pair{Symbol,String}[], "input", "Electrolysis capacity", "GWe")
    end
end

function _dataline_hydrogen_storage_cap(s; showforeign=true)
    nodeswithout = showforeign ? Symbol[] : [:foreign]
    d = __dataline_cap(s, [:hydrogen], nodeswithout, [:function => "storage"], Pair{Symbol,String}[], "level", "Hydrogen storage capacity", "GWh", 1E3)
    d.d[!,:zone] = replace.(String.(d.d[!,:zone]), r"^Hydrogen\s+" => "")
    return d
end


# demand response capacity is not trivial:
#  * there can be multiple capacities associated with it, that must all be shown here
#  * absence of capacity implies infinite capacity if a variable cost is defined
function _dataline_demandresponse_cap(s; showforeign=true)
    allcomps = String[]
    if showforeign
        allnodes = getnodes(s, with=[:electricity])
    else
        allnodes = getnodes(s, with=[:electricity], without=[:foreign])
    end
    allnode_comps = Dict(nodename => getcomponents(s, nodename, with=[:function => "demandresponse"]) for (nodename, _) in allnodes)
    for (_, d) in allnode_comps
        # list components connected to this zone (tech tag values, as in Excel sheet)
        for (_, comp) in d
            cname = only(get(comp.tags, :tech, String[]))
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])
    for (nodename,_) in allnodes
        v = Any[nodename]
        d = allnode_comps[nodename]
        compbytech = Dict(only(get(comp.tags, :tech, String[])) => comp for (_, comp) in d)
        for cname in allcomps
            c = get(compbytech, cname, nothing)
            if c === nothing
                push!(v, "")
            else
                vcap = Nosy.behaviors(c, Nosy.AbstractCapacityBehavior)
                vcost = Nosy.behaviors(c, Nosy.VariableCostBehavior)
                if isempty(vcap)
                    push!(v, string(Inf))
                else
                    vnumcap = []
                    for i in 1:length(vcost)
                        if i <= length(vcap)
                            push!(vnumcap, Nosy._capacity(vcap[i]) / 1E3)
                        else
                            push!(vnumcap, Inf) # infinite capacity is not modeled as a capacity, but it still has a variable cost
                        end
                    end
                    if length(vnumcap) == 1
                        push!(v, first(vnumcap))
                    else
                        push!(v, join(string.(vnumcap), " + "))
                    end
                end
            end
        end
        push!(df, permutedims(v))
    end

    # sum over zones and components
    # _lastrow = permutedims(vcat("Total", [sum(c) for c in eachcol(df)[2:end]]))
    # push!(df, _lastrow)
    # (ncol(df) > 1) &&  (df[!,"Total"] = sum(eachcol(df)[2:end]))

    return DataLine(
        "Demand response capacity",
        "GW",
        df
    )
end


function __dataline_yearly(s::Snapshot, modifier::Function, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Pair{Symbol,String}}, compswithout::Vector{Pair{Symbol,String}}, portname::String, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, with=nodeswith, without=nodeswithout) # not including foreign nodes
    allnode_comps = Dict(nodename => getcomponents(s, nodename, with=compswith, without=compswithout) for (nodename, _) in allnodes)
    for (_, d) in allnode_comps
        for (_, comp) in d
            cname = only(get(comp.tags, :tech, String[]))
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])

    for (nodename,_) in allnodes
        v = Any[nodename]
        d = allnode_comps[nodename]
        compbytech = Dict(only(get(comp.tags, :tech, String[])) => comp for (_, comp) in d)
        for cname in allcomps
            comp = get(compbytech, cname, nothing)
            if comp === nothing
                push!(v, 0.)
            else
                bout = balance(comp, :output, modifier, collapse=true, aggregate=false)
                if haskey(bout, portname)
                    push!(v, bout[portname] / factor)
                else
                    bin = balance(comp, :input, modifier, collapse=true, aggregate=false)
                    push!(v, haskey(bin, portname) ? bin[portname] / factor : 0.)
                end
            end
        end
        push!(df, permutedims(v))
    end

    # sum over zones and components
    _lastrow = permutedims(vcat("Total", [sum(c) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)
    (ncol(df) > 1) &&  (df[!,"Total"] = sum(eachcol(df)[2:end]))

    return DataLine(
        title,
        unit,
        df
    )
end

function _dataline_yearly_demand(s; showforeign=true)
    if showforeign
        d1 = __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "demand"], Pair{Symbol,String}[], "input", "Electrical final consumption (grid losses excluded)", "TWh/y", factor=1E6)
        d2 = __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "ev"], Pair{Symbol,String}[], "driving", "EV", "TWh/y", factor=1E6)
    else
        d1 = __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "demand"], Pair{Symbol,String}[], "input", "Electrical final consumption (grid losses excluded)", "TWh/y", factor=1E6)
        d2 = __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "ev"], Pair{Symbol,String}[], "driving", "EV", "TWh/y", factor=1E6)
    end
    # merge DataLines
    df = _merge_annual_df(d1.d, d2.d)
    d = DataLine(
        "Electrical final consumption (losses excluded)",
        "TWh/y",
        df
    )
end

function _dataline_yearly_production(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "generation"], Pair{Symbol,String}[], "output", "Electrical production (Net)", "TWh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "generation"], Pair{Symbol,String}[], "output", "Electrical production (Net)", "TWh/y", factor=1E6)
    end
end

function _dataline_yearly_charging(s; showforeign=true)
    if showforeign
        d1 = __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "storage"], Pair{Symbol,String}[], "input", "Storage charging", "TWh/y", factor=1E6)
        d2 = __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "ev"], Pair{Symbol,String}[], "input", "EV", "TWh/y", factor=1E6)
    else
        d1 = __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "storage"], Pair{Symbol,String}[], "input", "Storage charging", "TWh/y", factor=1E6)
        d2 = __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "ev"], Pair{Symbol,String}[], "input", "EV", "TWh/y", factor=1E6)
    end
    # merge DataLines
    df = _merge_annual_df(d1.d, d2.d)
    d = DataLine(
        "Storage charging (including V2G and non-V2G EVs)",
        "TWh/y",
        df
    )
end

function _dataline_yearly_discharging(s; showforeign=true)
    if showforeign
        d1 = __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "storage"], Pair{Symbol,String}[], "output", "Storage discharging", "TWh/y", factor=1E6)
        d2 = __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "ev"], Pair{Symbol,String}[], "output", "EV", "TWh/y", factor=1E6)
    else
        d1 = __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "storage"], Pair{Symbol,String}[], "output", "Storage discharging", "TWh/y", factor=1E6)
        d2 = __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "ev"], Pair{Symbol,String}[], "output", "EV", "TWh/y", factor=1E6)
    end
    df = _merge_annual_df(d1.d, d2.d)
    d = DataLine(
        "Storage discharging (including V2G EVs)",
        "TWh/y",
        df
    )
end

function _dataline_yearly_demandresponse(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "demandresponse"], Pair{Symbol,String}[], "output", "Demand response", "TWh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "demandresponse"], Pair{Symbol,String}[], "output", "Demand response", "TWh/y", factor=1E6)
    end
end

function _dataline_yearly_electrolysis(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:function => "electrolysis"], Pair{Symbol,String}[], "input", "Electrolysis", "TWh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:function => "electrolysis"], Pair{Symbol,String}[], "input", "Electrolysis", "TWh/y", factor=1E6)
    end
end

function _dataline_yearly_co2(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, co2, [:electricity], Symbol[], [:function => "generation"], Pair{Symbol,String}[], "co2", "CO2 emissions", "t/y", factor=1)
    else
        __dataline_yearly(s, co2, [:electricity], [:foreign], [:function => "generation"], Pair{Symbol,String}[], "co2", "CO2 emissions", "t/y", factor=1)
    end
end

# Interconnection topology, volumes, and annual IC datalines.

"""
    _fromto_ic_internal(s::Snapshot, ic::Component)
Return `(from, to)` node names for a node interconnection.
Direction follows builder ports `"input"` (from) and `"output"` (to); each port carrier
identifies the connected electricity node among nodes linked to this component.
"""
function _fromto_ic_internal(s::Snapshot, ic::Component)
    connected = String[]
    for (nodename, _) in getnodes(s, with=[:electricity])
        if haskey(getcomponents(s, nodename, with=[:function => "interconnection", :function => "nodeinterconnection"]), ic.name)
            push!(connected, nodename)
        end
    end
    length(connected) == 2 || throw(ArgumentError("node IC $(ic.name) expected 2 connected electricity nodes, got $(connected)"))

    carrier_from = Nosy.getport(ic, "input").carrier.name
    carrier_to = Nosy.getport(ic, "output").carrier.name

    from_candidates = String[]
    to_candidates = String[]
    for nodename in connected
        n = Nosy.getnode(s, nodename)
        n.carrier.name == carrier_from && push!(from_candidates, nodename)
        n.carrier.name == carrier_to && push!(to_candidates, nodename)
    end
    length(from_candidates) == 1 || throw(ArgumentError("node IC $(ic.name): input port carrier '$(carrier_from)' matched $(length(from_candidates)) connected nodes"))
    length(to_candidates) == 1 || throw(ArgumentError("node IC $(ic.name): output port carrier '$(carrier_to)' matched $(length(to_candidates)) connected nodes"))

    _from = only(from_candidates)
    _to = only(to_candidates)
    @assert _from != _to "node IC $(ic.name): input and output ports map to the same node"
    return (_from, _to)
end

"""
    _fromto_ic_external(s::Snapshot, ic::Component)
Return `(from, to)` node names for a price interconnection.
`from` is the external neighbor zone (`:neighbor` tag); `to` is the local electricity node connected to the component.
"""
function _fromto_ic_external(s::Snapshot, ic::Component)
    zones = get(ic.tags, :neighbor, String[])
    _from = only(zones)
    _to = ""
    # find local electricity node connected to this price IC
    for (nodename, _) in getnodes(s, with=[:electricity])
        if haskey(getcomponents(s, nodename, with=[:function => "interconnection", :function => "priceinterconnection"]), ic.name)
            _to = nodename
            break
        end
    end
    isempty(_to) && throw(ArgumentError("local node not found for price IC $(ic.name)"))
    return (_from, _to)
end

# return sorted electricity node names, including external neighbor zones from price ICs
function _ic_quasinodes(s::Snapshot)
    allquasinodes = Set{String}()
    allnodes = getnodes(s, with=[:electricity])
    for (_, c) in getcomponents(s, with=[:function => "interconnection", :function => "priceinterconnection"])
        union!(allquasinodes, get(c.tags, :neighbor, String[]))
    end
    return vcat(sort(collect(keys(allnodes)))..., sort(collect(allquasinodes))...)
end

# return both directed energy flows for an interconnection component (from, to, flow) tuples
function _ic_directed_flows(s::Snapshot, c::Component; collapse=true)
    if hastag(c, :function, "nodeinterconnection")
        (_from, _to) = _fromto_ic_internal(s, c)
        fwd = balance(c, :input, energy, aggregate=false, collapse=collapse)["input"]
        rev = balance(c, :input, energy, aggregate=false, collapse=collapse)["input2"]
    else
        (_from, _to) = _fromto_ic_external(s, c)
        fwd = balance(c, :output, energy, aggregate=false, collapse=collapse)["output"]
        rev = balance(c, :input, energy, aggregate=false, collapse=collapse)["input"]
    end
    return ((_from, _to, fwd), (_to, _from, rev))
end

function _all_ic_directed_flows(s::Snapshot; collapse=true)
    FlowT = Union{Float64, Nosy.AbstractTimeSeries{Float64}}
    flows = Dict{Tuple{String, String}, FlowT}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            flows[(_from, _to)] = flow
        end
    end
    return flows
end

"""
    imports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with internal (non-foreign) imports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function imports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    d = LittleDict{String, Union{Float64, Nosy.AbstractTimeSeries{Float64}}}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            _to == nodename || continue
            _from == nodename && continue
            haskey(selfnodes, _from) || continue
            d[_from] = flow
        end
    end
    collapse && return sum(values(d), init=0.0)
    return d
end

"""
    exports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with internal (non-foreign) exports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function exports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    d = LittleDict{String, Union{Float64, Nosy.AbstractTimeSeries{Float64}}}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            _from == nodename || continue
            _to == nodename && continue
            haskey(selfnodes, _to) || continue
            d[_to] = flow
        end
    end
    collapse && return sum(values(d), init=0.0)
    return d
end

"""
    imports_all(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with all (internal and foreign) imports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function imports_all(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String, Union{Float64, Nosy.AbstractTimeSeries{Float64}}}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            _to == nodename || continue
            _from == nodename && continue
            d[_from] = flow
        end
    end
    collapse && return sum(values(d), init=0.0)
    return d
end

"""
    exports_all(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with all (internal and foreign) exports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function exports_all(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String, Union{Float64, Nosy.AbstractTimeSeries{Float64}}}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            _from == nodename || continue
            _to == nodename && continue
            d[_to] = flow
        end
    end
    collapse && return sum(values(d), init=0.0)
    return d
end

"""
    imports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with external (foreign) imports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function imports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    d = LittleDict{String, Union{Float64, Nosy.AbstractTimeSeries{Float64}}}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            _to == nodename || continue
            haskey(selfnodes, _from) && continue
            d[_from] = flow
        end
    end
    collapse && return sum(values(d), init=0.0)
    return d
end

"""
    exports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with external (foreign) exports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function exports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    d = LittleDict{String, Union{Float64, Nosy.AbstractTimeSeries{Float64}}}()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            _from == nodename || continue
            haskey(selfnodes, _to) && continue
            d[_to] = flow
        end
    end
    collapse && return sum(values(d), init=0.0)
    return d
end

"""
    imports_foreign(s::Snapshot; collapse=true)
Return a Dict of the time series associated with external (foreign) interconnection imports in Snapshot `s`.
Dict keys are corridor labels `"from > to"`. If `collapse`, return a Dict of values instead.
"""
function imports_foreign(s; collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    dv = LittleDict()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            haskey(selfnodes, _to) || continue
            haskey(selfnodes, _from) && continue
            dv[string(_from, " > ", _to)] = flow
        end
    end
    return dv
end

"""
    imports_internal(s::Snapshot; collapse=true)
Return a Dict of the time series associated with internal (non-foreign) interconnection imports in Snapshot `s`.
Dict keys are corridor labels `"from > to"`. If `collapse`, return a Dict of values instead.
"""
function imports_internal(s; collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    dv = LittleDict()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            haskey(selfnodes, _to) || continue
            haskey(selfnodes, _from) || continue
            _from == _to && continue
            dv[string(_from, " > ", _to)] = flow
        end
    end
    return dv
end

"""
    imports_all(s::Snapshot; collapse=true)
Return a Dict of the time series associated with all (internal and foreign) interconnection imports in Snapshot `s`.
Dict keys are corridor labels `"from > to"`. If `collapse`, return a Dict of values instead.
"""
function imports_all(s; collapse=true)
    allnodes = getnodes(s, with=[:electricity])
    dv = LittleDict()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            haskey(allnodes, _to) || continue
            _from == _to && continue
            dv[string(_from, " > ", _to)] = flow
        end
    end
    return dv
end

"""
    exports_foreign(s::Snapshot; collapse=true)
Return a Dict of the time series associated with external (foreign) interconnection exports in Snapshot `s`.
Dict keys are corridor labels `"from > to"`. If `collapse`, return a Dict of values instead.
"""
function exports_foreign(s; collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    dv = LittleDict()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            haskey(selfnodes, _from) || continue
            haskey(selfnodes, _to) && continue
            dv[string(_from, " > ", _to)] = flow
        end
    end
    return dv
end

"""
    exports_internal(s::Snapshot; collapse=true)
Return a Dict of the time series associated with internal (non-foreign) interconnection exports in Snapshot `s`.
Dict keys are corridor labels `"from > to"`. If `collapse`, return a Dict of values instead.
"""
function exports_internal(s; collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    dv = LittleDict()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            haskey(selfnodes, _from) || continue
            haskey(selfnodes, _to) || continue
            _from == _to && continue
            dv[string(_from, " > ", _to)] = flow
        end
    end
    return dv
end

"""
    exports_all(s::Snapshot; collapse=true)
Return a Dict of the time series associated with all (internal and foreign) interconnection exports in Snapshot `s`.
Dict keys are corridor labels `"from > to"`. If `collapse`, return a Dict of values instead.
"""
function exports_all(s; collapse=true)
    allnodes = getnodes(s, with=[:electricity])
    dv = LittleDict()
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            haskey(allnodes, _from) || continue
            _from == _to && continue
            dv[string(_from, " > ", _to)] = flow
        end
    end
    return dv
end

# return a dataframe with interconnectors capacities
# this includes both interconnection between explicit nodes
# and interconnection from price time series
function _dataline_ic_cap(s)
    allcomps_int = Set{String}()
    allcomps_ext = Set{String}()
    allquasinodes = Set{String}()
    allnodes = getnodes(s, with=[:electricity])
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "nodeinterconnection"])
        push!(allcomps_int, cname)
    end
    ext_fromto = Dict{String, Tuple{String,String}}()
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "priceinterconnection"])
        push!(allcomps_ext, cname)
        ft = _fromto_ic_external(s, c)
        ext_fromto[cname] = ft
        push!(allquasinodes, ft[1])
    end

    allquasinodes = vcat(sort(collect(keys(allnodes)))..., sort(collect(allquasinodes))...)    
    df = DataFrame("From \\ To" => allquasinodes)
    for k in allquasinodes
        df[!,k] = convert(Vector{Union{String,Float64,Missing}}, fill(missing, length(allquasinodes)))
    end

    for cname in allcomps_int
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_internal(s, c)
        if Nosy.hascapacitybehavior(c, "input")
            df[df[!,"From \\ To"] .== _from, _to] .= capacity(c, "input") / 1E3
        end
        if Nosy.hascapacitybehavior(c, "input2")
            df[df[!,"From \\ To"] .== _to, _from] .= capacity(c, "input2") / 1E3
        end
    end

    for cname in allcomps_ext
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = ext_fromto[cname]
        if Nosy.hascapacitybehavior(c, "output")
            df[df[!,"From \\ To"] .== _from, _to] .= capacity(c, "output") / 1E3
        end
        if Nosy.hascapacitybehavior(c, "input")
            df[df[!,"From \\ To"] .== _to, _from] .= capacity(c, "input") / 1E3
        end
    end

    # rename columns and first row to clarify sense
    df[!,1] .*= " >"
    for n in names(df)[2:end]
        rename!(df, n => "> " * n)
    end

    # sum over zones
    datacols = names(df)[2:end]
    df[!,"> Total"] = [sum(df[i, c] for c in datacols if !ismissing(df[i, c])) for i in 1:nrow(df)]
    _lastrow = permutedims(vcat("Total >", [sum(x for x in c if !ismissing(x)) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)

    return DataLine(
        "Interconnection capacity",
        "GW",
        df
    )
end

# return a DataLine with the number of hours per year each node interconnection is at its NTC
# (From \ To matrix; node IC corridors only, same endpoints as the original corridor list)
function _dataline_ic_hours_at_ntc(s)
    allcomps_int = Set{String}()
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "nodeinterconnection"])
        push!(allcomps_int, cname)
    end

    zonenames = sort(collect(keys(getnodes(s, with=[:electricity]))))
    df = DataFrame("From \\ To" => zonenames)
    for k in zonenames
        df[!, k] = Union{Missing, Float64}[missing for _ in zonenames]
    end

    # Binding: flow and capacity in MW; atol = 1 W.
    for cname in allcomps_int
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_internal(s, c)
        for (port, row_zone, col_zone) in (("input", _from, _to), ("input2", _to, _from))
            val = if Nosy.hascapacitybehavior(c, port)
                flow = balance(c, :input, energy, collapse=false, aggregate=false)[port]
                cap = capacity(c, port, multiplier=true)
                n = 0
                for t in eachindex(flow, cap)
                    cap_t = cap[t]
                    cap_t > 0 && isapprox(cap_t, flow[t]; atol=1e-6, rtol=0) && (n += 1)
                end
                Float64(n)
            else
                missing
            end
            df[df[!, "From \\ To"] .== row_zone, col_zone] .= Ref(val)
        end
    end

    df[!, 1] .*= " >"
    for n in names(df)[2:end]
        rename!(df, n => "> " * n)
    end

    datacols = names(df)[2:end]
    df[!, "> Total"] = [sum((df[i, c] for c in datacols if !ismissing(df[i, c])); init=0.0) for i in 1:nrow(df)]
    _lastrow = permutedims(vcat("Total >", [sum((x for x in c if !ismissing(x)); init=0.0) for c in eachcol(df)[2:end]],))
    push!(df, _lastrow)

    return DataLine("Hours at NTC", "h/y", df)
end

# build an interconnection volume matrix (From \ To layout)
function _ic_vol_detailed(s; collapse=true, addtotal=false)
    allquasinodes = _ic_quasinodes(s)

    df = DataFrame("From \\ To" => allquasinodes .* " >")
    for k in allquasinodes
        col = "> " * k
        df[!, col] = Union{Missing, Float64, Nosy.Stepwise{Float64}, Nosy.Hourly{Float64}}[
            missing for _ in allquasinodes
        ]
    end

    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            row = string(_from, " >")
            col = "> " * _to
            df[df[!, "From \\ To"] .== row, col] .= Ref(flow)
        end
    end

    if addtotal
        datacols = names(df)[2:end]
        df[!, "> Total"] = [sum(df[i, c] for c in datacols if !ismissing(df[i, c])) for i in 1:nrow(df)]
        _lastrow = permutedims(vcat("Total >", [sum(x for x in c if !ismissing(x)) for c in eachcol(df)[2:end]]))
        push!(df, _lastrow)
    end

    return df
end

# return a line containing dataframe with interconnection volumes
# this includes both interconnection between explicit nodes
# and interconnection from price time series
function _dataline_ic_vol_detailed(s)
    
    df = _ic_vol_detailed(s, addtotal=true)

    # divide the values by 1E6 (MWh -> TWh)
    df = (x -> x isa Number ? x / 1E6 : x).(df)

    return DataLine(
        "Interconnection volume",
        "TWh/y",
        df
    )
end

# return a line with detail of annual imports
function _dataline_imports_vol(s)
    dv = imports_foreign(s, collapse=true)
    dv["Total"] = sum(values(dv), init=0.)
    d = DataLine(
        "Imports",
        "TWh/y",
        LittleDict(k=>v/1E6 for (k,v) in dv)
    )
    return d
end

# return a line with detail of annual exports
function _dataline_exports_vol(s)
    dv = exports_foreign(s, collapse=true)
    dv["Total"] = sum(values(dv), init=0.)
    d = DataLine(
        "Exports",
        "TWh/y",
        LittleDict(k=>v/1E6 for (k,v) in dv)
    )
    return d
end

function _dataline_net_ic_vol(s)
    flows = _all_ic_directed_flows(s; collapse=true)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    imp = Dict{Tuple{String, String}, Float64}()
    exp = Dict{Tuple{String, String}, Float64}()
    for ((from, to), flow) in flows
        if haskey(selfnodes, to) && !haskey(selfnodes, from)
            imp[(from, to)] = flow
        end
        if haskey(selfnodes, from) && !haskey(selfnodes, to)
            exp[(from, to)] = flow
        end
    end
    net = Dict{Tuple{String, String}, Float64}()
    for ((from, to), val) in imp
        net[(from, to)] = val - get(exp, (to, from), 0.0)
    end
    for ((from, to), val) in exp
        haskey(imp, (to, from)) && continue
        net[(to, from)] = -val
    end
    total = sum(values(net), init=0.0)
    labeled = LittleDict(string(from, " > ", to) => v / 1E6 for ((from, to), v) in net)
    labeled["Total"] = total / 1E6
    return DataLine(
        "Net interconnection volume",
        "TWh/y (negative is export)",
        labeled,
    )
end

# return a line with detail of annual capacity factors
# evaluated as ratio of energy produced over energy that could have been produced
function _dataline_capacityfactors(s; showforeign=true)
    dfp = _dataline_yearly_production(s, showforeign=showforeign).d[1:end-1,1:end-1]
    dfc = _dataline_elec_prod_cap(s, showforeign=showforeign).d[1:end-1,1:end-1]

    df = DataFrame([name => Vector{Union{String,Float64}}(undef,nrow(dfp)) for name in names(dfp)])
    df[!,"zone"] = dfp[!,"zone"]
    for cname in names(dfp)[2:end]
        df[!,cname] = dfp[!,cname] ./ dfc[!,cname] / 8760 * 1E3
    end

    # average over zones
    _lastrow = permutedims(vcat("Weighted average", [sum(dfp[!, c]) / sum(dfc[!, c]) / 8760 * 1E3 for c in names(df)[2:end]]))
    push!(df, _lastrow)

    # replace NaN with empty string
    df = (x->(x isa Number && isnan(x)) ? "" : x).(df)

    return DataLine(
        "Power plants capacity factors",
        "Energy %",
        df
    )
end

# return a line with detail of annual capacity factors of electrolysers
# evaluated as ratio of energy produced over energy that could have been produced
function _dataline_electrolysers_capacityfactors(s; showforeign=true)
    dfp = _dataline_yearly_electrolysis(s, showforeign=showforeign).d[1:end-1,1:end-1]
    isempty(dfp) && return nothing
    dfc = _dataline_electrolysis_cap(s, showforeign=showforeign).d[1:end-1,1:end-1]

    df = DataFrame([name => Vector{Union{String,Float64}}(undef,nrow(dfp)) for name in names(dfp)])
    df[!,"zone"] = dfp[!,"zone"]
    for cname in names(dfp)[2:end]
        df[!,cname] = dfp[!,cname] ./ dfc[!,cname] / 8760 * 1E3
    end

    # average over zones
    _lastrow = permutedims(vcat("Weighted average", [sum(dfp[!, c]) / sum(dfc[!, c]) / 8760 * 1E3 for c in names(df)[2:end]]))
    push!(df, _lastrow)

    # replace NaN with empty string
    df = (x->(x isa Number && isnan(x)) ? "" : x).(df)

    return DataLine(
        "Electrolysers capacity factors",
        "Energy %",
        df
    )
end

# return a line containing a dataframe containing the cost categories for the different components
function _dataline_costs(s; showforeign=true)
    if showforeign
        df = costs(s)
    else
        df = selfcosts(s)
    end

    # filter out items not associated with costs
    vcomp = getcomponents(s, without=[:function => "demand"])
    for cname in collect(df[!,"component"]) # prevent lazy iteration because we modify the df
        if !haskey(vcomp, cname) && cname != "all"
            deleteat!(df, df[!,"component"] .== cname)
        end
    end
    
    df2 = DataFrame()
    df2[!,"Component"] = df[!,:"component"]
    
    # set default order for cost items
    # add non-default cost items at the end
    # add total after all other cost items
    basecats = names(df)[2:end-1]
    cats = ["investment", "fom", "fuel", "vom", "imports", "exports", "transaction", "co2"] # re-order columns vs costs
    notinbase = setdiff(basecats, cats)
    push!(cats, notinbase...)
    push!(cats, "total")

    _diff = setdiff(names(df)[2:end-1], cats[1:end-1])
    @assert isempty(_diff) "Cost items $_diff were forgotten"
    for n in cats
        if n in names(df)
            df2[!,n] = df[!,n] / 1E9 #
        end
    end
    # @assert isapprox(sum(eachcol(df2)[2:end-1]), df2[!,end]) "The sum of costs is not equal to the total - a category is probably missing"
    return DataLine(
        "Detailed costs",
        "Billion USD (2024)",
        df2
    )
end

# return a line with the cost of the physical system and the interconnection costs
function _dataline_costs_aggregated(s; showforeign=true)
    if showforeign
        dfcosts = costs(s)
    else
        dfcosts = selfcosts(s)
    end

    _total = first(dfcosts[dfcosts[!,"component"] .== "all", "total"])

    _iccols = ("imports", "exports", "congestionrent")
    local _ic = 0.
    for cname in _iccols
        if cname in names(dfcosts)
            _ic += first(dfcosts[dfcosts[!,"component"] .== "all", cname])
        end
    end

    _physical = _total - _ic

    return DataLine(
        "Aggregated costs (Physical = system except interconnection, trade = only interconnection)",
        "Billions USD (2024)",
        LittleDict(
            "Physical" => _physical / 1E9,
            "Trade" => _ic / 1E9,
            "Total" => _total / 1E9,
        )
    )
end

function __dataline_yearly_price_received(s::Snapshot, modifier::Function, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Pair{Symbol,String}}, compswithout::Vector{Pair{Symbol,String}}, portname::String, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, with=nodeswith, without=nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, with=compswith, without=compswithout)
        for (_, comp) in d
            cname = only(get(comp.tags, :tech, String[]))
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps, ["Weighted average"])])

    for (nodename,n) in allnodes
        price = Nosy.Hourly(Nosy.dualprice(n), sim(s).mesh)
        v = Any[nodename]
        d = getcomponents(s, nodename, with=compswith, without=compswithout)
        dbytech = Dict{String,Vector{Component}}()
        for (_, comp) in d
            tech = only(get(comp.tags, :tech, String[]))
            push!(get!(dbytech, tech, Component[]), comp)
        end
        for cname in allcomps
            comps = get(dbytech, cname, Component[])
            if isempty(comps)
                push!(v, "")
            else
                local wsum = 0.0
                local fsum = 0.0
                for c in comps
                    bout = balance(c, :output, modifier, collapse=false, aggregate=false)
                    if haskey(bout, portname)
                        f = sum(bout[portname])
                        if !iszero(f)
                            wsum += sum(bout[portname] .* price)
                            fsum += f
                        end
                    end
                end
                if iszero(fsum)
                    push!(v, "")
                else
                    push!(v, wsum / fsum / factor)
                end
            end
        end
        push!(v, sum(balance(n, :output, energy, collapse=false, aggregate=true) .* price) / balance(n, :output, energy, collapse=true, aggregate=true))
        push!(df, permutedims(v))
    end

    return DataLine(
        title,
        unit,
        df
    )
end

function _dataline_yearly_price_received(s; showforeign=true)
    if showforeign
        __dataline_yearly_price_received(s, energy, [:electricity], Symbol[], [:function => "generation"], Pair{Symbol,String}[], "output", "Average price received", "USD/MWh", factor=1)
    else
        __dataline_yearly_price_received(s, energy, [:electricity], [:foreign], [:function => "generation"], Pair{Symbol,String}[], "output", "Average price received", "USD/MWh", factor=1)
    end
end

function __dataline_yearly_cost(s::Snapshot, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Pair{Symbol,String}}, compswithout::Vector{Pair{Symbol,String}}, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, with=nodeswith, without=nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, with=compswith, without=compswithout)
        for (_, comp) in d
            cname = only(get(comp.tags, :tech, String[]))
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])

    for (nodename,n) in allnodes
        v = Any[nodename]
        d = getcomponents(s, nodename, with=compswith, without=compswithout)
        dbytech = Dict{String,Vector{Component}}()
        for (_, comp) in d
            tech = only(get(comp.tags, :tech, String[]))
            push!(get!(dbytech, tech, Component[]), comp)
        end
        for cname in allcomps
            comps = get(dbytech, cname, Component[])
            if isempty(comps)
                push!(v, 0.)
            else
                push!(v, sum(cost(s, Nosy.name(c)) for c in comps) / factor)
            end
        end
        push!(df, permutedims(v))
    end

    # sum over zones and components
    _lastrow = permutedims(vcat("Total", [sum(c) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)
    (ncol(df) > 1) &&  (df[!,"Total"] = sum(eachcol(df)[2:end]))

    return DataLine(
        title,
        unit,
        df
    )
end


function _dataline_yearly_cost(s; showforeign=true)
    if showforeign
        __dataline_yearly_cost(s, [:electricity], Symbol[], [:function => "generation"], Pair{Symbol,String}[], "Components costs", "Billions USD (2024)", factor=1E9)
    else
        __dataline_yearly_cost(s, [:electricity], [:foreign], [:function => "generation"], Pair{Symbol,String}[], "Components costs", "Billions USD (2024)", factor=1E9)
    end
end

function __dataline_yearly_earnings(s::Snapshot, modifier::Function, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Pair{Symbol,String}}, compswithout::Vector{Pair{Symbol,String}}, portname::String, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, with=nodeswith, without=nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, with=compswith, without=compswithout)
        for (_, comp) in d
            cname = only(get(comp.tags, :tech, String[]))
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])

    for (nodename,n) in allnodes
        price = Nosy.Hourly(Nosy.dualprice(n), sim(s).mesh)
        v = Any[nodename]
        d = getcomponents(s, nodename, with=compswith, without=compswithout)
        dbytech = Dict{String,Vector{Component}}()
        for (_, comp) in d
            tech = only(get(comp.tags, :tech, String[]))
            push!(get!(dbytech, tech, Component[]), comp)
        end
        for cname in allcomps
            comps = get(dbytech, cname, Component[])
            if isempty(comps)
                push!(v, 0.)
            else
                local _val = 0.0
                for c in comps
                    bout = balance(c, :output, modifier, collapse=false, aggregate=false)
                    if haskey(bout, portname) && !iszero(sum(bout[portname]))
                        _val += sum(bout[portname] .* price) / factor
                    end
                end
                push!(v, _val)
            end
        end
        push!(df, permutedims(v))
    end

    # sum over zones and components
    _lastrow = permutedims(vcat("Total", [sum(c) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)
    (ncol(df) > 1) &&  (df[!,"Total"] = sum(eachcol(df)[2:end]))

    return DataLine(
        title,
        unit,
        df
    )
end


function _dataline_yearly_earnings(s; showforeign=true)
    if showforeign
        __dataline_yearly_earnings(s, energy, [:electricity], Symbol[], [:function => "generation"], Pair{Symbol,String}[], "output", "Components earnings", "Billions USD (2024)", factor=1E9)
    else
        __dataline_yearly_earnings(s, energy, [:electricity], [:foreign], [:function => "generation"], Pair{Symbol,String}[], "output", "Components earnings", "Billions USD (2024)", factor=1E9)
    end
end

function _dataline_lcoe(s; showforeign=true)
    dfp = _dataline_yearly_production(s, showforeign=showforeign).d[1:end-1,1:end-1]
    dfc = _dataline_yearly_cost(s; showforeign=showforeign).d[1:end-1,1:end-1]

    df = DataFrame([name => Vector{Union{String,Float64}}(undef,nrow(dfp)) for name in names(dfp)])
    df[!,"zone"] = dfp[!,"zone"]
    for cname in names(dfp)[2:end]
        v = dfc[!,cname] ./ dfp[!,cname] * 1E3
        df[!,cname] = v
    end

    # average over zones
    _lastrow = permutedims(vcat("Weighted average", [sum(dfc[!, c]) / sum(dfp[!, c]) * 1E3 for c in names(df)[2:end]]))
    push!(df, _lastrow)

    # replace NaN with empty string
    df = (x->(x isa Number && isnan(x)) ? "" : x).(df)

    return DataLine(
        "Power plants LCOE",
        "USD/MWhe",
        df
    )
end

# apply all post-processings to a snapshot, return as a vector of DataLine
function _annual_post_processing_self(s::Snapshot)
    _postprocessings = (
        x->_dataline_demand_prod(x, showforeign=false),
        x->_dataline_yearly_demand(x, showforeign=false),
        x->_dataline_elec_prod_cap(x, showforeign=false),
        x->_dataline_demandresponse_cap(x, showforeign=false),
        x->_dataline_electrolysis_cap(x, showforeign=false),
        x->_dataline_hydrogen_storage_cap(x, showforeign=false),
        x->_dataline_elec_storage_cap(x, showforeign=false),
        x->_dataline_elec_storage_discharge_cap(x, showforeign=false),
        x->_dataline_elec_storage_cap_level(x; showforeign=false), 
        _dataline_ic_cap,
        _dataline_ic_hours_at_ntc,
        x->_dataline_yearly_production(x, showforeign=false),
        x->_dataline_yearly_charging(x, showforeign=false),
        x->_dataline_yearly_discharging(x, showforeign=false),
        x->_dataline_yearly_demandresponse(x, showforeign=false),
        # x->_dataline_yearly_ev_consumption(x, showforeign=false),
        x->_dataline_yearly_electrolysis(x, showforeign=false),
        _dataline_ic_vol_detailed,
        x->_dataline_imports_vol(x),
        x->_dataline_exports_vol(x),
        x->_dataline_net_ic_vol(x),
        x->_dataline_capacityfactors(x, showforeign=false),
        x->_dataline_electrolysers_capacityfactors(x, showforeign=false),
        x->_dataline_yearly_co2(x, showforeign=false),
        x->_dataline_yearly_cost(x, showforeign=false),
        x->_dataline_yearly_earnings(x, showforeign=false),
        x->_dataline_yearly_price_received(x, showforeign=false),
        x->_dataline_lcoe(x, showforeign=false),
        x->_dataline_costs(x, showforeign=false),
        x->_dataline_costs_aggregated(x, showforeign=false),
    )
    return [f(s) for f in _postprocessings]
end

function _annual_post_processing_all(s::Snapshot)
    _postprocessings = (
        x->_dataline_demand_prod(x, showforeign=true),
        x->_dataline_yearly_demand(x, showforeign=true),
        x->_dataline_elec_prod_cap(x, showforeign=true),
        x->_dataline_demandresponse_cap(x, showforeign=true),
        x->_dataline_electrolysis_cap(x, showforeign=true),
        x->_dataline_hydrogen_storage_cap(x, showforeign=true),
        x->_dataline_elec_storage_cap(x, showforeign=true),
        x->_dataline_elec_storage_discharge_cap(x, showforeign=true),
        x->_dataline_elec_storage_cap_level(x; showforeign=true),
        _dataline_ic_cap,
        _dataline_ic_hours_at_ntc,
        x->_dataline_yearly_production(x, showforeign=true),
        x->_dataline_yearly_charging(x, showforeign=true),
        x->_dataline_yearly_discharging(x, showforeign=true),
        x->_dataline_yearly_demandresponse(x, showforeign=true),
        # x->_dataline_yearly_ev_consumption(x, showforeign=true),
        x->_dataline_yearly_electrolysis(x, showforeign=true),
        _dataline_ic_vol_detailed,
        x->_dataline_capacityfactors(x, showforeign=true),
        x->_dataline_electrolysers_capacityfactors(x, showforeign=true),
        x->_dataline_yearly_co2(x, showforeign=true),
        x->_dataline_yearly_earnings(x, showforeign=true),
        x->_dataline_yearly_cost(x, showforeign=true),
        x->_dataline_yearly_price_received(x, showforeign=true),
        x->_dataline_lcoe(x, showforeign=true),
        x->_dataline_costs(x, showforeign=true),
        x->_dataline_costs_aggregated(x, showforeign=true),
    )
    return [f(s) for f in _postprocessings]
end
