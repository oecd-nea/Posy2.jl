# basic annualized cost
# used if no construction profile is given
function _eac(overnight::Number, discountrate, years)
    return overnight * discountrate / (1 - (1 + discountrate)^(-years))
end

"""
    eac(overnight::Number, discountrate::Number, lifetime::Int, constructionprofile::String)
Return the annualized investment cost in function of the overnight cost, the discount rate, the lifetime and the construction profile.
The effects are the following:
  * total cost (financing taking construction time into account + overnight)
  * annualization via corrected CRF (so that operation starts right after construction, no white year)
"""
function eac(overnight::Number, discountrate::Number, lifetime, constructionprofile)
    if ismissing(constructionprofile)
        return _eac(overnight * (1+discountrate), discountrate, 1) # if constructionprofile is not given, assume 1 year of construction (the year before operation)
    else
        vc = isa(constructionprofile, String) ? parse.(Float64, split(constructionprofile, ';')) : [constructionprofile] # construction profile is given in the chronological order
        @assert isapprox(sum(vc), 1., rtol=1E-3) "Sum of the construction profile is not equal to 1"
        overnight * sum((vc[y]) * (1 + discountrate)^(length(vc)+1-y) for y in eachindex(vc)) * corrected_crf(discountrate, lifetime)
    end
end

#version of capital recovery factor that does not consider year 0 as a white year
corrected_crf(discountrate, lifetime) = discountrate / (1 + discountrate) / (1 - (1 + discountrate)^(-lifetime))



# decommissioning cost in function of overnight cost, lifetime and discount rate
function decom_cost(overnight::Number, deco_ratio, lifetime, discountrate)
    # overnight cost
    # * decommissioning ratio
    # * discounting because paid at end of lifetime
    # * annualization factor
    return overnight * deco_ratio * (1 + discountrate)^(-lifetime) * discountrate / (1 + discountrate) / (1 - (1 + discountrate)^(-lifetime))
end