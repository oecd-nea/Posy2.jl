function eac(overnight::Number, discountrate, years)
    return overnight * discountrate / (1 - (1 + discountrate)^(-years))
end

function eac(overnight::Number, discountrate, lifetime, constructionprofile)
    if ismissing(constructionprofile)
        return eac(overnight * (1+discountrate), discountrate, years) # if constructionprofile is not given, assume 1 year of construction (the year before operation)
    else
        vc = parse.(Float64, split(constructionprofile, ';')) # construction profile is given in the chronological order
        @assert isapprox(sum(vc), 1.) "Sum of the construction profile is not equal to 1"
        sum((overnight * vc[y]) * (1 + discountrate)^(length(vc)+1-y) for y in eachindex(vc)) * discountrate / (1 - (1 + discountrate)^(-lifetime))
    end
end

# decommissioning cost in function of overnight cost, lifetime and discount rate
function decom_cost(overnight::Number, deco_ratio, lifetime::Int, discountrate)
    # overnight cost
    # * decommissioning ratio
    # * discounting because paid at end of lifetime
    # * annualization factor
    return overnight * deco_ratio * (1 + discountrate)^(-lifetime) * discountrate / (1 - (1 + discountrate)^(-lifetime))
end