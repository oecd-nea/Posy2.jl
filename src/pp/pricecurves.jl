"""
Price duration curves.
"""

function genpricecurves(s::Snapshot)
    df = DataFrame()
    
    if JuMP.has_duals(sim(s).model)
        for (nname, n) in getnodes(s, [:electricity])
            df[!,nname] = sort(Nosy.dualprice(n), rev=true)
        end
    end

    for (cname, c) in getcomponents(s, [:interconnection, :foreign], Symbol[])
        _name = split(cname, '_')[2]
        df[!,_name] = sort(getexogenousprice(c), rev=true)
    end

    return df
end

