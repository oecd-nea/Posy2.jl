"""
Post-processing functions.

The functions below rely on the tag system 
"""

# return exports time series
function ic_vol_sense1(s; aggregate=false, collapse=false, showforeign=true)
    d = LittleDict()
    dcomps = getcomponents(s, [:interconnection], Symbol[]) # only considering components connected with foreign nodes
    for (k,v) in dcomps
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input2"]
    end
    aggregate && return sum(values(d))
    return d
end

# return imports time series
function ic_vol_sense2(s; aggregate=false, collapse=false, showforeign=true)
    d = LittleDict()
    dcomps = getcomponents(s, [:interconnection], Symbol[])
    for (k,v) in dcomps
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["output"]
    end
    aggregate && return sum(values(d))
    return d
end

function rewrite_export_from_implicit(name::String)
    vn = split(name, '_')
    return string(vn[3] * " > " * vn[2])
end

function rewrite_import_from_implicit(name::String)
    vn = split(name, '_')
    return string(vn[2] * " > " * vn[3])
end

function reverse_interco_sense(name::String)
    vn = split(name, " > ")
    return string(vn[2] *  " > " * vn[1])
end


function availabletransfercapacities(s) # no aggregate or collapse options (no meaning)
    d = LittleDict()
    dcomps = getcomponents(s, [:interconnection, :foreign], Symbol[]) # only considering components connected with foreign nodes
    for (k,v) in dcomps
        d["ATC " * rewrite_import_from_implicit(k)] = capacity(v, "output", multiplier=true)
        d["ATC " * rewrite_export_from_implicit(k)] = capacity(v, "input", multiplier=true)
    end
    return d
end


# return production time series in MWhe
function production(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, [:generation], Symbol[])
    for (k,v) in dcomps
        d[k] = balance(v, :output, energy, collapse=collapse, aggregate=false)["output"]
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return charging time series in MWhe
function charging(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, [:storage], Symbol[])
    for (k,v) in dcomps
        b = balance(v, :input, energy, collapse=collapse, aggregate=false)
        if haskey(b, "input")
            d["charging "* k] = b["input"]
        end
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return natural intake time series in MWhe
function intake(s; aggregate=false, collapse=false)
    d = LittleDict()
    dcomps = getcomponents(s, [:storage], Symbol[])
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
    dcomps = getcomponents(s, [:storage], Symbol[])
    for (k,v) in dcomps
        d["level " * k] = Nosy.Hourly(v.model.s.level["level"].series, sim(s).mesh)
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

# return demand time series in MWhe
function demand(s; aggregate=false, collapse=false)
    d = LittleDict()
    de = getcomponents(s, [:demand, :electricity], Symbol[]) # consumption of demand-type components
    dh = getcomponents(s, [:electrolysis], Symbol[]) # consumption of electrolyser-type components
    for (k,v) in merge(de, dh)
        d[k] = balance(v, :input, energy, collapse=collapse, aggregate=false)["input"]
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end

function demand(s, nodename::String; aggregate=false, collapse=false)
    d = demand(s, aggregate=false, collapse=collapse)
    d2 = Dict()
    for (k,v) in d
        s = split(k, ' ')
        if s[end] == nodename
            d2[k] = v
        end
    end
    aggregate && return sum(values(d2))
    return d2
end

# return curtailment time series in MWhe
curtailment(s; collapse=true) = sum(curtailment(s, z, collapse=collapse) for (z,_) in s.nodes)

# return lossestime series in MWhe
function losses(s; aggregate=false, collapse=true)
    d = LittleDict()
    for (nname, _) in getnodes(s, [:electricity], Symbol[])
        d[nname] = sum([losses(s, cname, modifier=energy, collapse=collapse) for (cname, c) in getcomponents(s, nname, Symbol[], Symbol[])])
    end
    aggregate && return sum(values(d), init=zeros(Nosy.nhours(sim(s))))
    return d
end