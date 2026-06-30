"""
Price duration curves.
"""

"""
    genpricecurves(s::Snapshot)
Return a DataFrame of price duration curves for Snapshot `s`.
Columns are electricity node names and external zones linked by price interconnections.
Each column contains hourly prices sorted in descending order (same units as in Snapshot `s`).
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
    for (cname, c) in getcomponents(s, with=[:function => "interconnection", :function => "priceinterconnection"])
        zones = get(c.tags, :neighbor, String[])
        df[!, only(zones)] = sort(getexogenousprice(c), rev=true)
    end

    return df
end
