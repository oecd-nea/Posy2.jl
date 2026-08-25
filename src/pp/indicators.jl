"""
Post-processing functions.

The functions below rely on the tag system 
"""

"""
    netinterconnection(s; collapse=false)
Return the net interconnection time series of the self system in MWhe: flows entering
self (non-`:foreign`) electricity nodes from outside minus flows leaving them, summed
over every interconnection. Positive means net imports.

Orientation comes from the endpoints' foreignness, not from builder port names, so a
corridor with both endpoints on the same side of the boundary contributes nothing, and
swapping the endpoints passed to a builder does not change the result. A node
interconnection endpoint is foreign when its node is tagged `:foreign`; a price
interconnection has no counterparty node, so its `foreign` tag (`makepriceinterco(...;
foreign)`) decides, and a `foreign=false` corridor to another internal zone is excluded.
Flows are measured at the sending end, as in the annual interconnection tables.
"""
function netinterconnection(s; collapse=false)
    selfnodes = getnodes(s, with=[:electricity], without=[:foreign])
    net = _aggregate_init(s, collapse)
    for (_, c) in getcomponents(s, with=[:function => "interconnection"])
        isprice = hastag(c, :function, "priceinterconnection")
        isprice && !hastag(c, :function, "foreign") && continue # priced internal zone: no boundary crossing
        extzone = isprice ? only(get(c.tags, :neighbor, String[])) : nothing # implicit endpoint, never self
        for (_from, _to, flow) in _ic_directed_flows(s, c; collapse=collapse)
            from_self = _from != extzone && haskey(selfnodes, _from)
            to_self = _to != extzone && haskey(selfnodes, _to)
            from_self == to_self && continue # internal transfer, or foreign transit: no boundary crossing
            net = to_self ? net .+ flow : net .- flow
        end
    end
    return net
end

# rewrite interconnection component names to "from > to" flow labels for reporting
function rewrite_export_from_implicit(s::Snapshot, cname::String, c::Component)
    if hastag(c, :function, "priceinterconnection")
        zones = get(c.tags, :neighbor, String[])
        extzone = only(zones)
        for (nodename, _) in getnodes(s, with=[:electricity])
            if haskey(getcomponents(s, nodename, with=[:function => "interconnection", :function => "priceinterconnection"]), cname)
                return string(nodename, " > ", extzone)
            end
        end
        throw(ArgumentError("local node not found for price IC $(cname)"))
    else
        (_from, _to) = _fromto_ic_internal(s, c)
        return string(_to, " > ", _from)
    end
end

function rewrite_import_from_implicit(s::Snapshot, cname::String, c::Component)
    if hastag(c, :function, "priceinterconnection")
        zones = get(c.tags, :neighbor, String[])
        extzone = only(zones)
        for (nodename, _) in getnodes(s, with=[:electricity])
            if haskey(getcomponents(s, nodename, with=[:function => "interconnection", :function => "priceinterconnection"]), cname)
                return string(extzone, " > ", nodename)
            end
        end
        throw(ArgumentError("local node not found for price IC $(cname)"))
    else
        (_from, _to) = _fromto_ic_internal(s, c)
        return string(_from, " > ", _to)
    end
end

function availabletransfercapacities(s) # no aggregate or collapse options (no meaning)
    d = LittleDict()
    for (k, v) in getcomponents(s, with=[:function => "interconnection"])
        # price ICs are foreign by builder intent (no modeled counterparty node);
        # node ICs are foreign when at least one connected node is tagged :foreign
        if hastag(v, :function, "priceinterconnection")
            hastag(v, :function, "foreign") || continue
            (_from, _to) = _fromto_ic_external(s, v)
            ports = (("output", _from, _to), ("input", _to, _from))
        else
            isempty(_node_ic_endpoints(s, k)[3]) && continue
            (_from, _to) = _fromto_ic_internal(s, v)
            ports = (("input", _from, _to), ("input2", _to, _from))
        end
        for (port, pfrom, pto) in ports
            Nosy.hascapacitybehavior(v, port) || continue # unlimited direction: no ATC to report
            cap = capacity(v, port, multiplier=true)
            cap isa Real && (cap = fill(Float64(cap), Nosy.nhours(sim(s)))) # scalar = no multiplier; expand for hourly export
            key = "ATC " * string(pfrom, " > ", pto)
            d[key] = haskey(d, key) ? d[key] .+ cap : cap # AC and DC sharing a corridor sum
        end
    end
    return d
end


# neutral element for the `aggregate=true` sums below: collapsed entries are
# scalars, hourly entries are series. Also the value returned when no component
# matches the query.
_aggregate_init(s, collapse) = collapse ? 0.0 : zeros(Nosy.nhours(sim(s)))

# return production time series in MWhe
function production(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:function => "generation"])
    for (k,v) in dcomps
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["output"]
    end
    aggregate && return sum(values(d); init=_aggregate_init(s, collapse))
    return d
end

# return charging time series in MWhe
function charging(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = merge(getcomponents(s, with=[:function => "storage"]), getcomponents(s, with=[:function => "ev"]))
    for (k,v) in dcomps
        b = balance(v, :input, energy, collapse=collapse, aggregate=false)
        if haskey(b, "input")
            d["charging "* k] = b["input"]
        end
    end
    aggregate && return sum(values(d); init=_aggregate_init(s, collapse))
    return d
end

# return discharging time series in MWhe
function discharging(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = merge(getcomponents(s, with=[:function => "storage"]), getcomponents(s, with=[:function => "ev"]))
    for (k,v) in dcomps
        if Nosy.hasport(v, "output")
            b = balance(v, :output, energy, collapse=collapse, aggregate=false)
            if haskey(b, "output")
                d["discharging " * k] = b["output"]
            end
        end
    end
    aggregate && return sum(values(d); init=_aggregate_init(s, collapse))
    return d
end

# return natural intake time series in MWhe
function intake(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, with=[:function => "storage"])
    for (k,v) in dcomps
        b = balance(v, :input, energy, collapse=collapse, aggregate=false)
        if haskey(b, "natural")
            d["intake " * k] = b["natural"]
        end
    end
    aggregate && return sum(values(d); init=_aggregate_init(s, collapse))
    return d
end

# return spillage time series in MWhe
function spillage(s; aggregate=false, collapse=false)
    d = LittleDict()
    for (k,v) in getcomponents(s, with=[:function => "storage"])
        if Nosy.hasport(v, "spill")
            b = balance(v, :output, energy, collapse=collapse, aggregate=false)
            d["spillage " * k] = b["spill"]
        end
    end
    aggregate && return sum(values(d); init=_aggregate_init(s, collapse))
    return d
end

# return storagelevel time series in MWhe
function storagelevel(s; aggregate=false)
    d = LittleDict()
    dcomps = merge(getcomponents(s, with=[:function => "storage"]), getcomponents(s, with=[:function => "ev"]))
    for (k,v) in dcomps
        if Nosy.hasport(v, "level")
            d["level " * k] = balance(v, :level, energy, collapse=false, aggregate=true)
        end
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# EV driving consumption: `driving`, or `departure - arrival`
function _ev_driving(c; collapse::Bool)
    if Nosy.hasport(c, "departure")
        dep = balance(c, :output, energy, collapse=collapse, aggregate=false)["departure"]
        arr = balance(c, :input, energy, collapse=collapse, aggregate=false)["arrival"]
        return dep - arr
    end
    return balance(c, :output, energy, collapse=collapse, aggregate=false)["driving"]
end

# return demand time series in MWhe
function demand(s; aggregate=false, collapse=false)
    d = LittleDict()
    de = getcomponents(s, with=[:function => "demand", :function => "electricity"]) # consumption of demand-type components
    dh = getcomponents(s, with=[:function => "electrolysis"]) # consumption of electrolyser-type components
    dev = getcomponents(s, with=[:function => "ev"]) # consumption of ev-type components
    for (k,v) in merge(de, dh)
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    for (k,v) in dev
        d[k] = _ev_driving(v; collapse=collapse)
    end
    aggregate && return sum(values(d); init=_aggregate_init(s, collapse))
    return d
end

function demand(s, nodename::String; aggregate=false, collapse=false)
    d = LittleDict()
    for (k, v) in getcomponents(s, nodename, with=[:function => "demand", :function => "electricity"])
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    for (k, v) in getcomponents(s, nodename, with=[:function => "electrolysis"])
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    for (k, v) in getcomponents(s, nodename, with=[:function => "ev"])
        d[k] = _ev_driving(v; collapse=collapse)
    end
    if aggregate
        ini = collapse ? 0.0 : zeros(Nosy.nhours(sim(s)))
        return sum(values(d); init=ini)
    end
    return d
end

# return curtailment time series in MWhe
curtailment(s; collapse=true) = sum(curtailment(s, z, collapse=collapse) for (z,_) in s.nodes)
