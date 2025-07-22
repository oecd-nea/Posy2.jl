
# return a dataframe filled with time series related to the snapshot
# power time series are in GWe
# prices time series are in €/MWhe
function gentimeseries(s::Snapshot)
    cons = demand(s, collapse=false, aggregate=true)
    imp = ic_vol_sense2(s, collapse=false, aggregate=true)
    exp = ic_vol_sense1(s, collapse=false, aggregate=true)
    atc = availabletransfercapacities(s)
    prod = production(s, collapse=false, aggregate=true)
    char = charging(s, collapse=false, aggregate=true)
    inta = intake(s, collapse=false, aggregate=true)
    los = losses(s, collapse=false, aggregate=true)
    lev = storagelevel(s, aggregate=true)
    curt = curtailment(s, collapse=false)
    df = DataFrame()

    df[!,"Hour"] = 1:8760
    df[!,"Total demand"] = cons / 1000.
    df[!,"Total losses"] = los / 1000.
    df[!,"Total net interconnection"] = (imp - exp) / 1000.
    df[!,"Total production"] = prod / 1000.
    df[!,"Total charging"] = char / 1000.
    df[!,"Total intake"] = inta / 1000.
    df[!,"Total curtailment"] = curt / 1000.
    df[!,"Total level"] = lev / 1000.

    dprod = production(s, collapse=false, aggregate=false)
    for (k,v) in dprod
        df[!,k] = v / 1000.
    end

    dchar = charging(s, collapse=false, aggregate=false)
    for (k,v) in dchar
        df[!,k] = v / 1000.
    end

    dinta = intake(s, collapse=false, aggregate=false)
    for (k,v) in dinta
        df[!,k] = v / 1000.
    end

    dlev = storagelevel(s, aggregate=false)
    for (k,v) in dlev
        df[!,k] = v / 1000.
    end

    # TODO internal IC
       
    # available transfer capacities (GW)
    for (k,v) in atc
        df[!,k] = v / 1000.
    end

    dimp = LittleDict(rewrite_import_from_implicit(k)=>v for (k,v) in ic_vol_sense2(s, collapse=false, aggregate=false))
    dexp = LittleDict(rewrite_export_from_implicit(k)=>v for (k,v) in ic_vol_sense1(s, collapse=false, aggregate=false))
    for (k,v) in dimp
        df[!,k] = v / 1000.
        kinv = reverse_interco_sense(k)
        df[!,kinv] = dexp[kinv] / 1000.
    end

    # price from electricity nodes
    if JuMP.has_duals(sim(s).model)
        for (nname, n) in getnodes(s, [:electricity])
            df[!,"price " * nname] = Nosy.dualprice(n)
        end
    else
        @warn "Model has no duals - dual price evaluation is skipped"
        for (nname, n) in getnodes(s, [:electricity])
            df[!,"price " * nname] .= "not evaluated"
        end
    end

    # average price from price interconnection components (average of buying price and selling price)
    for (cname, c) in getcomponents(s, [:interconnection, :priceinterconnection], Symbol[])
        df[!,"price " * cname] = getexogenousprice(c)
    end

    return df
end

"""
    getexogenousprice(c::Component)
Return the exogenous price time series of a component.
The component must be an implicit interconnection component, associated with a price time series.
""" 
function getexogenousprice(c::Component)
    @assert startswith(Nosy.name(c), "IC") "The component does not look like an interconnection"
    vb = Nosy.getbehaviors(c, Nosy.VariableCostBehavior{Float64})
    vp = Vector{Float64}[]
    for b in vb
        if Nosy._costtype(b) == :imports
            push!(vp, Nosy.Hourly(b.data.val, sim(c).mesh).data)
        elseif Nosy._costtype(b) == :exports
            push!(vp, -Nosy.Hourly(b.data.val, sim(c).mesh).data)
        end
    end
    return sum(vp) / length(vp) # average
end