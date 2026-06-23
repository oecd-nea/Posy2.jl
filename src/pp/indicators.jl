"""
Post-processing functions.

The functions below rely on the tag system 
"""

# return exports time series
function ic_vol_sense1(s; aggregate=false, collapse=false, showforeign=true)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:interconnection]) # only considering components connected with foreign nodes
    for (k,v) in dcomps
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input2"]
    end
    aggregate && return sum(values(d))
    return d
end

# return imports time series
function ic_vol_sense2(s; aggregate=false, collapse=false, showforeign=true)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:interconnection])
    for (k,v) in dcomps
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["output"]
    end
    aggregate && return sum(values(d))
    return d
end

# rewrite interconnection component names to "from > to" flow labels for reporting
function rewrite_export_from_implicit(s::Snapshot, cname::String, c::Component)
    if hastag(c, :priceinterconnection)
        kind = (:interconnection, :priceinterconnection, :foreign)
        zones = [t for t in c.tags if !(t in kind)]
        length(zones) == 1 || throw(ArgumentError("price IC $(cname): expected 1 external zone tag, got $(zones)"))
        extzone = string(only(zones))
        for (nodename, _) in getnodes(s, with=[:electricity])
            if haskey(getcomponents(s, nodename, with=[:priceinterconnection]), cname)
                return string(nodename, " > ", extzone)
            end
        end
        throw(ArgumentError("local node not found for price IC $(cname)"))
    elseif hastag(c, :nodeinterconnection)
        (_from, _to) = _fromto_ic_internal(s, c)
        return string(_to, " > ", _from)
    else
        throw(ArgumentError("interconnection $(cname) must be :priceinterconnection or :nodeinterconnection, got tags $(c.tags)"))
    end
end

function rewrite_import_from_implicit(s::Snapshot, cname::String, c::Component)
    if hastag(c, :priceinterconnection)
        kind = (:interconnection, :priceinterconnection, :foreign)
        zones = [t for t in c.tags if !(t in kind)]
        length(zones) == 1 || throw(ArgumentError("price IC $(cname): expected 1 external zone tag, got $(zones)"))
        extzone = string(only(zones))
        for (nodename, _) in getnodes(s, with=[:electricity])
            if haskey(getcomponents(s, nodename, with=[:priceinterconnection]), cname)
                return string(extzone, " > ", nodename)
            end
        end
        throw(ArgumentError("local node not found for price IC $(cname)"))
    elseif hastag(c, :nodeinterconnection)
        (_from, _to) = _fromto_ic_internal(s, c)
        return string(_from, " > ", _to)
    else
        throw(ArgumentError("interconnection $(cname) must be :priceinterconnection or :nodeinterconnection, got tags $(c.tags)"))
    end
end

function reverse_interco_sense(name::String)
    vn = split(name, " > ")
    return string(vn[2] *  " > " * vn[1])
end


function availabletransfercapacities(s) # no aggregate or collapse options (no meaning)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:interconnection, :foreign]) # only considering components connected with foreign nodes
    for (k,v) in dcomps
        d["ATC " * rewrite_import_from_implicit(s, k, v)] = capacity(v, "output", multiplier=true)
        d["ATC " * rewrite_export_from_implicit(s, k, v)] = capacity(v, "input", multiplier=true)
    end
    return d
end


# return production time series in MWhe
function production(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:generation])
    for (k,v) in dcomps
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["output"]
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return charging time series in MWhe
function charging(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = merge(getcomponents(s, with=[:storage]), getcomponents(s, with=[:ev]))
    for (k,v) in dcomps
        b = balance(v, :input, energy, collapse=collapse, aggregate=false)
        if haskey(b, "input")
            d["charging "* k] = b["input"]
        end
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return discharging time series in MWhe
function discharging(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = merge(getcomponents(s, with=[:storage]), getcomponents(s, with=[:ev]))
    for (k,v) in dcomps
        if Nosy.hasport(v, "output")
            b = balance(v, :output, energy, collapse=collapse, aggregate=false)
            if haskey(b, "output")
                d["discharging " * k] = b["output"]
            end
        end
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return natural intake time series in MWhe
function intake(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:storage])
    for (k,v) in dcomps
        b = balance(v, :input, energy, collapse=collapse, aggregate=false)
        if haskey(b, "natural")
            d["intake " * k] = b["natural"]
        end
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return storagelevel time series in MWhe
function storagelevel(s; aggregate=false)
    d = LittleDict()
    dcomps = merge(getcomponents(s, with=[:storage]), getcomponents(s, with=[:ev]))
    for (k,v) in dcomps
        if Nosy.hasport(v, "level")
            d["level" * k] = balance(v, :level, energy, collapse=false, aggregate=true)
        end
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return demand time series in MWhe
function demand(s; aggregate=false, collapse=false)
    d = LittleDict()
    de = getcomponents(s, with=[:demand, :electricity]) # consumption of demand-type components
    dh = getcomponents(s, with=[:electrolysis]) # consumption of electrolyser-type components
    dev = getcomponents(s, with=[:ev]) # consumption of ev-type components
    for (k,v) in merge(de, dh)
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    for (k,v) in dev
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["driving"]
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

function demand(s, nodename::String; aggregate=false, collapse=false)
    d = LittleDict()
    for (k, v) in getcomponents(s, nodename, with=[:demand, :electricity])
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    for (k, v) in getcomponents(s, nodename, with=[:electrolysis])
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    for (k, v) in getcomponents(s, nodename, with=[:ev])
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["driving"]
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return curtailment time series in MWhe
curtailment(s; collapse=true) = sum(curtailment(s, z, collapse=collapse) for (z,_) in s.nodes)

# return lossestime series in MWhe
function losses(s; aggregate=false, collapse=true)
    d = LittleDict()
    for (nname, _) in getnodes(s, with=[:electricity])
        d[nname] = sum([losses(s, cname, modifier=energy, collapse=collapse) for (cname, c) in getcomponents(s, nname)])
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end
