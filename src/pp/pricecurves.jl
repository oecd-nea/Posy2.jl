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

    # price duration curves for external zones linked by price interconnections
    for (cname, c) in getcomponents(s, with=[:priceinterconnection])
        kind = (:interconnection, :priceinterconnection, :foreign)
        zones = [t for t in c.tags if !(t in kind)]
        length(zones) == 1 || throw(ArgumentError("price IC $(cname): expected 1 external zone tag, got $(zones)"))
        df[!, string(only(zones))] = sort(getexogenousprice(c), rev=true)
    end

    return df
end
