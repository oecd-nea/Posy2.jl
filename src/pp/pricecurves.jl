"""
Price duration curves.
"""

function genpricecurves(s::Snapshot)
    df = DataFrame()
    
    for (nname, n) in getnodes(s, with=[:electricity])
        price = Nosy.dualprice(n)
        if !isnothing(price)
            df[!,nname] = sort(price, rev=true)
        end
    end

    for (cname, c) in getcomponents(s, with=[:interconnection, :foreign])
        _name = split(cname, '_')[2]
        df[!,_name] = sort(getexogenousprice(c), rev=true)
    end

    return df
end
