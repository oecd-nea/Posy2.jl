
"""
    gentimeseries(s::Snapshot)
Return a DataFrame of hourly post-processing time series related to Snapshot `s`.
Power time series are in GWe. Price time series use the same units as in Snapshot `s`.
"""
function gentimeseries(s::Snapshot)
    cons = demand(s, collapse=false, aggregate=true)
    imp = ic_vol_sense2(s, collapse=false, aggregate=true)
    exp = ic_vol_sense1(s, collapse=false, aggregate=true)
    atc = availabletransfercapacities(s)
    prod = production(s, collapse=false, aggregate=true)
    char = charging(s, collapse=false, aggregate=true)
    dis = discharging(s, collapse=false, aggregate=true)
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
    df[!,"Total discharging"] = dis / 1000.
    df[!,"Total intake"] = inta / 1000.
    df[!,"Total curtailment"] = curt / 1000.
    df[!,"Total level"] = lev / 1000.

    dcons = demand(s, collapse=false, aggregate=false)
    for (k,v) in dcons
        df[!,k] = v / 1000.
    end

    dprod = production(s, collapse=false, aggregate=false)
    for (k,v) in dprod
        df[!,k] = v / 1000.
    end

    dchar = charging(s, collapse=false, aggregate=false)
    for (k,v) in dchar
        df[!,k] = v / 1000.
    end

    ddis = discharging(s, collapse=false, aggregate=false)
    for (k,v) in ddis
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

    # available transfer capacities (GW)
    for (k,v) in atc
        df[!,k] = v / 1000.
    end

    # interconnection import/export volumes (column names: from > to)
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "nodeinterconnection"])
        df[!, rewrite_import_from_implicit(s, cname, c)] = balance(c, :output, energy, collapse=false, aggregate=false)["output"] / 1000.
        df[!, rewrite_export_from_implicit(s, cname, c)] = balance(c, :input, energy, collapse=false, aggregate=false)["input2"] / 1000.
    end
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "priceinterconnection"])
        df[!, rewrite_import_from_implicit(s, cname, c)] = balance(c, :output, energy, collapse=false, aggregate=false)["output"] / 1000.
        df[!, rewrite_export_from_implicit(s, cname, c)] = balance(c, :input, energy, collapse=false, aggregate=false)["input"] / 1000.
    end

    # price from electricity nodes
    for (nname, n) in getnodes(s, with=[:electricity])
        price = Nosy.dualprice(n)
        if isnothing(price)
            df[!,"price " * nname] .= "not evaluated"
        else
            df[!,"price " * nname] = price
        end
    end

    # average price from price interconnection components (average of buying price and selling price)
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "priceinterconnection"])
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
    hastag(c, :function, "priceinterconnection") || throw(ArgumentError("expected :function=>\"priceinterconnection\" on $(c.name)"))
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
