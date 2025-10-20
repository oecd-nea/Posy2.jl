using OrderedCollections: LittleDict
using Nosy: nhours
using Infiltrator


"""
    losses(s::Snapshot, compname::String; modifier=energy, collapse=true)
Return the time series associated with grid losses of `modifier` in component named `compname` of Snapshot `s`.
If `collapse`, return a value instead.
"""
function losses(s::Snapshot, compname::String; modifier=energy, collapse=true)
    b = balance(Nosy.getcomponent(s, compname), :input, modifier, collapse=collapse, aggregate=false)
    if haskey(b, "grid losses")
        return b["grid losses"]
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
    d = getcomponents(s, nodename, [:generation])
    val = sum([balance(v, :output, modifier, collapse=collapse, aggregate=true) for (k,v) in d], init=ini)
    return val  
end

"""
    charging(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with charging of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function charging(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = getcomponents(s, nodename, [:storage])
    if collapse
        local c = 0.
    else
        local c = zeros(nhours(s.sim))
    end
    for (_,v) in d
        b = balance(v, :input, modifier, collapse=collapse, aggregate=false)
        if haskey(b, "input")
            c += b["input"]
        end
    end
    return c
end

function storageloss(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = getcomponents(s, nodename, [:storage])
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
    imports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with internal (non-foreign) imports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function imports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String,Float64}()
    for (k,v) in imports_internal(s, collapse=collapse)
        s = split(k, ' ')
        if s[3] == nodename
            d[s[1]] = v
        end
    end

    collapse && return sum(values(d)) # TODO replace collapse w aggregate
end

"""
    exports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with internal (non-foreign) exports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function exports_internal(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String,Float64}()
    for (k,v) in exports_internal(s, collapse=collapse)
        s = split(k, ' ')
        if s[1] == nodename
            d[s[3]] = v
        end
    end

    collapse && return sum(values(d)) # TODO replace collapse w aggregate

    return d
end

function imports_all(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String,Float64}()
    for (k,v) in imports_all(s, collapse=collapse)
        s = split(k, ' ')
        if s[3] == nodename
            d[s[1]] = v
        end
    end

    collapse && return sum(values(d)) # TODO replace collapse w aggregate
end

function exports_all(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String,Float64}()
    for (k,v) in exports_all(s, collapse=collapse)
        s = split(k, ' ')
        if s[1] == nodename
            d[s[3]] = v
        end
    end

    collapse && return sum(values(d)) # TODO replace collapse w aggregate

    return d
end

"""
    imports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with external (foreign) imports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function imports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String,Float64}()
    for (k,v) in imports_foreign(s, collapse=collapse)
        s = split(k, ' ')
        if s[3] == nodename
            d[s[1]] = v
        end
    end

    collapse && return sum(values(d)) # TODO replace collapse w aggregate

    return d
end

"""
    exports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
Return a Dict of the time series associated with external (foreign) exports of `modifier` in node named `nodename` of Snapshot `s`.
If `collapse`, return a Dict of values instead.
"""
function exports_foreign(s::Snapshot, nodename::String; modifier=energy, collapse=true)
    d = LittleDict{String,Float64}()
    for (k,v) in exports_foreign(s, collapse=collapse)
        s = split(k, ' ')
        if s[1] == nodename
            d[s[3]] = v
        end
    end

    collapse && return sum(values(d)) # TODO replace collapse w aggregate

    return d
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
            if k != "losses" && hastag(Nosy.getcomponent(s, k), :curtailment)
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
    d = getcomponents(s, nodename, [:demandresponse])
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
    d = getcomponents(s, nodename, [:electrolysis])
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
        enodes = getnodes(s, [:electricity], Symbol[])
    else
        enodes = getnodes(s, [:electricity], [:foreign])
    end
    
    d = LittleDict()
    d["zone"] = [k for (k,_) in enodes]
    d["Final consumption incl. electrolysis"] = [demand(s, k, aggregate=true, collapse=true)/1E6 for (k,_) in enodes]
    d["Production"] = [production(s, k)/1E6 for (k,_) in enodes] # includes discharging
    d["Charging"] = [charging(s, k)/1E6 for (k,_) in enodes]
    # d["Storage losses"] = [storageloss(s,k)/1E6 for (k,_) in enodes] # already counted in charging
    d["Grid losses"] = [sum([losses(s, cname)/1E6 for (cname, c) in getcomponents(s, k, Symbol[], Symbol[])], init=0.)  for (k,_) in enodes]
    d["Electrolysis"] = [electrolysis(s,k)/1E6 for (k,_) in enodes]

    if showforeign
        d["Imports"] = [imports_all(s,k)/1E6 for(k,_) in enodes]
        d["Exports"] = [exports_all(s,k)/1E6 for(k,_) in enodes]
    else
        d["Imports (internal)"] = [imports_internal(s,k)/1E6 for(k,_) in enodes]
        d["Exports (internal)"] = [exports_internal(s,k)/1E6 for(k,_) in enodes]
        d["Imports (foreign)"] = [imports_foreign(s,k)/1E6 for(k,_) in enodes]
        d["Exports (foreign)"] = [exports_foreign(s,k)/1E6 for(k,_) in enodes]
    end
    d["Demand response"] = [demandresponse(s,k)/1E6 for (k,_) in enodes]
    d["Curtailment"] = [curtailment(s,k)/1E6 for(k,_) in enodes]

    df = DataFrame(d)

    # df = DataFrame(
    #     LittleDict(
    #         "zone" => [k for (k,_) in enodes],
    #         "Demand" => [demand(s, k)/1E6 for (k,_) in enodes],
    #         "Losses" => [losses(s, k)/1E6 for (k,_) in enodes],
    #         "Production" => [production(s, k)/1E6 for (k,_) in enodes],
    #         "Electrolysis" => [electrolysis(s,k)/1E6 for (k,_) in enodes],
    #         "Charging" => [charging(s, k)/1E6 for (k,_) in enodes], 
    #         "Imports (internal)" => [imports_internal(s,k)/1E6 for(k,_) in enodes],
    #         "Exports (internal)" => [exports_internal(s,k)/1E6 for(k,_) in enodes],
    #         "Imports (foreign)" => [imports_foreign(s,k)/1E6 for(k,_) in enodes],
    #         "Exports (foreign)" => [exports_foreign(s,k)/1E6 for(k,_) in enodes],
    #         "Curtailment" => [curtailment(s,k)/1E6 for(k,_) in enodes],
    #         "Demand response" => [demandresponse(s,k)/1E6 for (k,_) in enodes],
    #     )
    # )

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
function __dataline_cap(s::Snapshot, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Symbol}, compswithout::Vector{Symbol}, portname::String, title::String, unit::String, coeff=1E3)
    allcomps = String[]
    allnodes = getnodes(s, nodeswith, nodeswithout)
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, compswith, compswithout)
        lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
        for cname in lcomps
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)
    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])
    for (nodename,_) in allnodes
        v = Any[nodename]
        for cname in allcomps
            cname2 = cname * " " * nodename
            if Nosy.hascomponent(s, cname2)
                c = Nosy.getcomponent(s, cname2)
                if Nosy.hasport(c, portname)
                    cap = capacity(c, portname)
                    if !isnothing(cap)
                        push!(v, cap / coeff)
                    else
                        push!(v, Inf)
                    end
                else
                    push!(v, 0.)
                end
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
        __dataline_cap(s, [:electricity], Symbol[], [:generation], Symbol[], "output", "Electrical production capacity", "GWe")
    else
        __dataline_cap(s, [:electricity], [:foreign], [:generation], Symbol[], "output", "Electrical production capacity", "GWe")
    end
end

function _dataline_elec_storage_cap(s; showforeign=true) 
    if showforeign
        __dataline_cap(s, [:electricity], Symbol[], [:storage], Symbol[], "input", "Electrical storage charging capacity", "GWe")
    else
        __dataline_cap(s, [:electricity], [:foreign], [:storage], Symbol[], "input", "Electrical storage charging capacity", "GWe")
    end
end

function _dataline_elec_storage_cap_level(s; showforeign=true) 
    if showforeign
        __dataline_cap(s, [:electricity], Symbol[], [:storage], Symbol[], "level", "Electrical storage max level", "TWhe", 1E6)
    else
        __dataline_cap(s, [:electricity], [:foreign], [:storage], Symbol[], "level", "Electrical storage max level", "TWhe", 1E6)
    end
end

function _dataline_electrolysis_cap(s; showforeign=true) 
    if showforeign
        __dataline_cap(s, [:electricity], Symbol[], [:electrolysis], Symbol[], "input", "Electrolysis capacity", "GWe")
    else
        __dataline_cap(s, [:electricity], [:foreign], [:electrolysis], Symbol[], "input", "Electrolysis capacity", "GWe")
    end
end


# demand response capacity is not trivial:
#  * there can be multiple capacities associated with it, that must all be shown here
#  * absence of capacity implies infinite capacity if a variable cost is defined
function _dataline_demandresponse_cap(s; showforeign=true)
    allcomps = String[]
    if showforeign
        allnodes = getnodes(s, [:electricity], Symbol[])
    else
        allnodes = getnodes(s, [:electricity], [:foreign])
    end
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, [:demandresponse])
        lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
        for cname in lcomps
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])
    for (nodename,_) in allnodes
        v = Any[nodename]
        for cname in allcomps
            cname2 = cname * " " * nodename
            if Nosy.hascomponent(s, cname2)
                c = Nosy.getcomponent(s, cname2)
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
            else
                push!(v, "")
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


function __dataline_yearly(s::Snapshot, modifier::Function, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Symbol}, compswithout::Vector{Symbol}, portname::String, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, nodeswith, nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, compswith, compswithout)
        lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
        for cname in lcomps
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])

    for (nodename,_) in allnodes
        v = Any[nodename]
        for cname in allcomps
            cname2 = cname * " " * nodename
            if Nosy.hascomponent(s, cname2)
                bout = balance(s, cname2, :output, modifier, collapse=true, aggregate=false)
                if haskey(bout, portname)
                    push!(v, bout[portname] / factor)
                else
                    bin = balance(s, cname2, :input, modifier, collapse=true, aggregate=false)
                    if haskey(bin, portname)
                        push!(v, bin[portname] / factor)
                    else
                        push!(v, 0.)
                    end
                end
                # push!(v, balance(s, cname2, sense, energy, collapse=true, aggregate=false)[portname] / 1E6)
            else
                push!(v, 0.)
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
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:demand], Symbol[], "input", "Electrical final consumption (losses and electrolysis excluded)", "TWeh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:demand], Symbol[], "input", "Electrical final consumption (losses and electrolysis excluded)", "TWeh/y", factor=1E6)
    end
end

function _dataline_yearly_production(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:generation], Symbol[], "output", "Electrical production (Gross)", "TWeh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:generation], Symbol[], "output", "Electrical production (Gross)", "TWeh/y", factor=1E6)
    end
end

function _dataline_yearly_charging(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:storage], Symbol[], "input", "Storage charging", "TWeh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:storage], Symbol[], "input", "Storage charging", "TWeh/y", factor=1E6)
    end
end

function _dataline_yearly_demandresponse(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:demandresponse], Symbol[], "output", "Demand response", "TWeh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:demandresponse], Symbol[], "output", "Demand response", "TWeh/y", factor=1E6)
    end
end

function _dataline_yearly_electrolysis(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, energy, [:electricity], Symbol[], [:electrolysis], Symbol[], "input", "Electrolysis", "TWeh/y", factor=1E6)
    else
        __dataline_yearly(s, energy, [:electricity], [:foreign], [:electrolysis], Symbol[], "input", "Electrolysis", "TWeh/y", factor=1E6)
    end
end

function _dataline_yearly_co2(s; showforeign=true)
    if showforeign
        __dataline_yearly(s, co2, [:electricity], Symbol[], [:generation], Symbol[], "co2", "CO2 emissions", "t/y", factor=1)
    else
        __dataline_yearly(s, co2, [:electricity], [:foreign], [:generation], Symbol[], "co2", "CO2 emissions", "t/y", factor=1)
    end
end

# parse an node-based ic (as a component linking 2 nodes) name, return a tuple of node names (from, to) associated with this interconnection
function _fromto_ic_internal(s::Snapshot, ic::Component)
    elecnodes = getnodes(s, [:electricity])
    local _to = ""
    local _from = ""
    for (nodename, node) in elecnodes
        if endswith(ic.name, nodename)
            _to = nodename
            break
        end
    end
    @assert !isempty(_to) "Target node not found in interconnection $(ic.name)"
    _rem = rstrip(replace(ic.name, _to => ""), '_')
    for (nodename, node) in elecnodes
        if endswith(_rem, nodename)
            _from = nodename
            break
        end
    end
    @assert !isempty(_from) "Origin node not found in interconnection $(ic.name)"
    return (_from, _to)
end

# parse an external ic (with price time series) name, return a tuple of node names (from, to) associated with this interconnection
function _fromto_ic_external(s::Snapshot, ic::Component)
    elecnodes = getnodes(s, [:electricity])
    local _to = ""
    local _from = ""
    for (nodename, node) in elecnodes
        if endswith(ic.name, nodename)
            _to = nodename
            break
        end
    end
    @assert !isempty(_to) "Target node not found in interconnection $(ic.name)"
    _rem = rstrip(replace(ic.name, _to => ""), '_')

    _from = replace(_rem, "IC_" => "")
    return (_from, _to)
end

# return a dataframe with interconnectors capacities
# this includes both interconnection between explicit nodes
# and interconnection from price time series
function _dataline_ic_cap(s)
    allcomps_int = Set{String}()
    allcomps_ext = Set{String}()
    allquasinodes = Set{String}()
    allnodes = getnodes(s, [:electricity])
    for (nodename, _) in allnodes
        let d = getcomponents(s, nodename, [:interconnection, :nodeinterconnection])
            lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
            for cname in lcomps
                push!(allcomps_int, cname)
            end
        end
        let d = getcomponents(s, nodename, [:interconnection, :priceinterconnection])
            lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
            for cname in lcomps
                push!(allcomps_ext, cname)
                push!(allquasinodes, _fromto_ic_external(s, Nosy.getcomponent(s, cname))[1])
            end
        end
    end

    allquasinodes = vcat(sort(collect(keys(allnodes)))..., sort(collect(allquasinodes))...)    
    df = DataFrame([name => [] for name in vcat(["To \\ From"], allquasinodes)])

    df = DataFrame("From \\ To" => allquasinodes)
    for k in allquasinodes
        df[!,k] = convert(Vector{Union{String,Float64}}, fill(0., length(allquasinodes))) # zeros(length(allquasinodes))
    end

    for cname in allcomps_int
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_internal(s, c)
        df[df[!,"From \\ To"] .== _from, _to] .= capacity(c, "input") / 1E3
        df[df[!,"From \\ To"] .== _to, _from] .= capacity(c, "input2") / 1E3
    end

    for cname in allcomps_ext
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_external(s, c)
        df[df[!,"From \\ To"] .== _from, _to] .= capacity(c, "output") / 1E3
        df[df[!,"From \\ To"] .== _to, _from] .= capacity(c, "input") / 1E3
    end

    # rename columns and first row to clarify sense
    df[!,1] .*= " >"
    for n in names(df)[2:end]
        rename!(df, n => "> " * n)
    end

    # sum over zones
    df[!,"> Total"] = sum(eachcol(df)[2:end])
    _lastrow = permutedims(vcat("Total >", [sum(c) for c in eachcol(df)[2:end]]))
    push!(df, _lastrow)

    # replace zeros for readability
    df = (x->(x == 0.) ? nothing : x).(df)

    return DataLine(
        "Interconnection capacity",
        "GW",
        df
    )
end

function _interco_vol_detailed(s; collapse=true, addtotal=false)
    allcomps_int = Set{String}()
    allcomps_ext = Set{String}()
    allquasinodes = Set{String}()
    allnodes = getnodes(s, [:electricity])
    for (nodename, _) in allnodes
        let d = getcomponents(s, nodename, [:interconnection, :nodeinterconnection])
            lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
            for cname in lcomps
                push!(allcomps_int, cname)
            end
        end
        let d = getcomponents(s, nodename, [:interconnection, :priceinterconnection])
            lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
            for cname in lcomps
                push!(allcomps_ext, cname)
                push!(allquasinodes, _fromto_ic_external(s, Nosy.getcomponent(s, cname))[1])
            end
        end
    end

    allquasinodes = vcat(sort(collect(keys(allnodes)))..., sort(collect(allquasinodes))...)    
    df = DataFrame([name => [] for name in vcat(["To \\ From"], allquasinodes)])

    df = DataFrame("From \\ To" => allquasinodes)
    for k in allquasinodes
        df[!,k] = convert(Vector{Union{Nothing,Float64,Nosy.Stepwise{Float64}}}, fill(0., length(allquasinodes))) # zeros(length(allquasinodes))
    end

    for cname in allcomps_int
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_internal(s, c)
        df[df[!,"From \\ To"] .== _from, _to] .= Ref(balance(c, :input, energy, aggregate=false, collapse=collapse)["input"])
        df[df[!,"From \\ To"] .== _to, _from] .= Ref(balance(c, :input, energy, aggregate=false, collapse=collapse)["input2"])
    end

    for cname in allcomps_ext
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_external(s, c)
        df[df[!,"From \\ To"] .== _from, _to] .= Ref(balance(c, :output, energy, aggregate=false, collapse=collapse)["output"])
        df[df[!,"From \\ To"] .== _to, _from] .= Ref(balance(c, :input, energy, aggregate=false, collapse=collapse)["input"])
    end

    # rename columns and first row to clarify sense
    df[!,1] .*= " >"
    for n in names(df)[2:end]
        rename!(df, n => "> " * n)
    end
    
    if addtotal
        df[!,"> Total"] = sum(eachcol(df)[2:end])
        _lastrow = permutedims(vcat("Total >", [sum(c) for c in eachcol(df)[2:end]]))
        push!(df, _lastrow)
    end

    return df
end

# return a line containing dataframe with interconnection volumes
# this includes both interconnection between explicit nodes
# and interconnection from price time series
function _dataline_ic_vol_detailed(s)
    
    df = _interco_vol_detailed(s, addtotal=true)

    # replace zeros with dots for readability
    # divide the values by 1E6 (MWh -> TWh)
    df = (x->(x == 0.) ? nothing : (x isa Number ? x / 1E6 : x)).(df)

    return DataLine(
        "Interconnection volume",
        "TWh/y",
        df
    )
end

function imports_foreign(s; collapse=true)
    dv = LittleDict()

    df = _interco_vol_detailed(s, collapse=collapse, addtotal=false)
    selfnodes = getnodes(s, [:electricity], [:foreign])
    for (nodename, _) in selfnodes
        toname = "> " * nodename
        for fromname in df[!,"From \\ To"]
            if !haskey(selfnodes, first(split(fromname, ' ')))
                val = (df[df[!,"From \\ To"] .== fromname, toname])[]
                if !iszero(val)
                    dv[fromname * " " * nodename] = val
                end
            end
        end
    end

    return dv
end

function imports_internal(s; collapse=true)
    dv = LittleDict()

    df = _interco_vol_detailed(s, collapse=collapse, addtotal=false)
    selfnodes = getnodes(s, [:electricity], [:foreign])
    for (nodename, _) in selfnodes
        toname = "> " * nodename
        for fromname in df[!,"From \\ To"]
            if haskey(selfnodes, first(split(fromname, ' ')))
                val = (df[df[!,"From \\ To"] .== fromname, toname])[]
                if !iszero(val)
                    dv[fromname * " " * nodename] = val
                end
            end
        end
    end

    return dv
end

function imports_all(s; collapse=true)
    dv = LittleDict()

    df = _interco_vol_detailed(s, collapse=collapse, addtotal=false)
    selfnodes = getnodes(s, [:electricity], Symbol[])
    for (nodename, _) in selfnodes
        toname = "> " * nodename
        for fromname in df[!,"From \\ To"]
            val = (df[df[!,"From \\ To"] .== fromname, toname])[]
            if !iszero(val)
                dv[fromname * " " * nodename] = val
            end
        end
    end

    return dv
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


function exports_foreign(s; collapse=true)
    dv = LittleDict()

    df = _interco_vol_detailed(s, addtotal=false)
    selfnodes = getnodes(s, [:electricity], [:foreign])

    for (nodename, _) in selfnodes
        fromname = nodename * " >"
        for toname in names(df)[2:end]
            if !haskey(selfnodes, last(split(toname, ' ')))
                val = (df[df[!,"From \\ To"] .== fromname, toname])[]
                if !iszero(val)
                    dv[nodename * " " * toname] = val
                end
            end
        end
    end

    return dv
end

function exports_internal(s; collapse=true)
    dv = LittleDict()

    df = _interco_vol_detailed(s, addtotal=false)
    selfnodes = getnodes(s, [:electricity], [:foreign])

    for (nodename, _) in selfnodes
        fromname = nodename * " >"
        for toname in names(df)[2:end]
            if haskey(selfnodes, last(split(toname, ' ')))
                val = (df[df[!,"From \\ To"] .== fromname, toname])[]
                if !iszero(val)
                    dv[nodename * " " * toname] = val
                end
            end
        end
    end

    return dv
end

function exports_all(s; collapse=true)
    dv = LittleDict()

    df = _interco_vol_detailed(s, addtotal=false)
    selfnodes = getnodes(s, [:electricity], Symbol[])

    for (nodename, _) in selfnodes
        fromname = nodename * " >"
        for toname in names(df)[2:end]
            val = (df[df[!,"From \\ To"] .== fromname, toname])[]
            if !iszero(val)
                dv[nodename * " " * toname] = val
            end
        end
    end

    return dv
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
    df = _interco_vol_detailed(s, addtotal=false)
    selfnodes = getnodes(s, [:electricity], [:foreign])

    _im = LittleDict()
    for (nodename, _) in selfnodes
        toname = "> " * nodename
        for fromname in df[!,"From \\ To"]
            if !haskey(selfnodes, first(split(fromname, ' ')))
                val = (df[df[!,"From \\ To"] .== fromname, toname])[]
                if !iszero(val)
                    _im[fromname * " " * nodename] = val
                end
            end
        end
    end

    _ex = LittleDict()
    for (nodename, _) in selfnodes
        fromname = nodename * " >"
        for toname in names(df)[2:end]
            if !haskey(selfnodes, last(split(toname, ' ')))
                val = (df[df[!,"From \\ To"] .== fromname, toname])[]
                if !iszero(val)
                    _ex[nodename * " " * toname] = val
                end
            end
        end
    end

    _net = LittleDict()
    for (_i, _e) in zip(_im, _ex)
        @assert split(_i[1], ' ')[1] == split(_e[1], ' ')[end] "_im and _ex do not iterate in same order"
        @assert split(_i[1], ' ')[end] == split(_e[1], ' ')[1] "_im and _ex do not iterate in same order"
        _net[_i[1]] = _i[2] - _e[2]
    end
    _net["Total"] = sum(values(_net), init=0.)

    d = DataLine(
        "Net interconnection volume",
        "TWh/y (negative is export)",
        LittleDict(k=>v/1E6 for (k,v) in _net),
    )
    return d  
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
    vcomp = getcomponents(s, Symbol[], [:demand])
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

function __dataline_yearly_price_received(s::Snapshot, modifier::Function, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Symbol}, compswithout::Vector{Symbol}, portname::String, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, nodeswith, nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, compswith, compswithout)
        lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
        for cname in lcomps
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps, ["Weighted average"])])

    for (nodename,n) in allnodes
        price = Nosy.Hourly(Nosy.dualprice(n), sim(s).mesh)
        v = Any[nodename]
        for cname in allcomps
            cname2 = cname * " " * nodename
            if Nosy.hascomponent(s, cname2)
                bout = balance(s, cname2, :output, modifier, collapse=false, aggregate=false)
                if haskey(bout, portname) && !iszero(sum(bout[portname]))
                    push!(v, sum(bout[portname] .* price) / sum(bout[portname]) / factor)
                else
                    push!(v, "")
                end
            else
                push!(v, "")
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
        __dataline_yearly_price_received(s, energy, [:electricity], Symbol[], [:generation], Symbol[], "output", "Average price received", "USD/MWh", factor=1)
    else
        __dataline_yearly_price_received(s, energy, [:electricity], [:foreign], [:generation], Symbol[], "output", "Average price received", "USD/MWh", factor=1)
    end
end

function __dataline_yearly_cost(s::Snapshot, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Symbol}, compswithout::Vector{Symbol}, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, nodeswith, nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, compswith, compswithout)
        lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
        for cname in lcomps
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])

    for (nodename,n) in allnodes
        v = Any[nodename]
        for cname in allcomps
            cname2 = cname * " " * nodename
            if Nosy.hascomponent(s, cname2)
                push!(v, cost(s, cname2) / factor)
            else
                push!(v, 0.)
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
        __dataline_yearly_cost(s, [:electricity], Symbol[], [:generation], Symbol[], "Components costs", "Billions USD (2024)", factor=1E9)
    else
        __dataline_yearly_cost(s, [:electricity], [:foreign], [:generation], Symbol[], "Components costs", "Billions USD (2024)", factor=1E9)
    end
end

function __dataline_yearly_earnings(s::Snapshot, modifier::Function, nodeswith::Vector{Symbol}, nodeswithout::Vector{Symbol}, compswith::Vector{Symbol}, compswithout::Vector{Symbol}, portname::String, title::String, unit::String; factor=1)
    allcomps = String[]
    allnodes = getnodes(s, nodeswith, nodeswithout) # not including foreign nodes
    for (nodename, _) in allnodes
        d = getcomponents(s, nodename, compswith, compswithout)
        lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
        for cname in lcomps
            !(cname in allcomps) && push!(allcomps, cname)
        end
    end
    sort!(allcomps)

    df = DataFrame([name => [] for name in vcat(["zone"], allcomps)])

    for (nodename,n) in allnodes
        price = Nosy.Hourly(Nosy.dualprice(n), sim(s).mesh)
        v = Any[nodename]
        for cname in allcomps
            cname2 = cname * " " * nodename
            if Nosy.hascomponent(s, cname2)
                bout = balance(s, cname2, :output, modifier, collapse=false, aggregate=false)
                if haskey(bout, portname) && !iszero(sum(bout[portname]))
                    push!(v, sum(bout[portname] .* price) / factor)
                else
                    push!(v, 0.)
                end
            else
                push!(v, 0.)
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
        __dataline_yearly_earnings(s, energy, [:electricity], Symbol[], [:generation], Symbol[], "output", "Components earnings", "Billions USD (2024)", factor=1E9)
    else
        __dataline_yearly_earnings(s, energy, [:electricity], [:foreign], [:generation], Symbol[], "output", "Components earnings", "Billions USD (2024)", factor=1E9)
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
        x->_dataline_elec_storage_cap(x, showforeign=false),
        x->_dataline_elec_storage_cap_level(x; showforeign=false), 
        _dataline_ic_cap,
        x->_dataline_yearly_production(x, showforeign=false),
        x->_dataline_yearly_charging(x, showforeign=false),
        x->_dataline_yearly_demandresponse(x, showforeign=false),
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
        x->_dataline_elec_storage_cap(x, showforeign=true),
        x->_dataline_elec_storage_cap_level(x; showforeign=true),
        _dataline_ic_cap,
        x->_dataline_yearly_production(x, showforeign=true),
        x->_dataline_yearly_charging(x, showforeign=true),
        x->_dataline_yearly_demandresponse(x, showforeign=true),
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