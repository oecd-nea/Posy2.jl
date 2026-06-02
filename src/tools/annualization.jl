using ArgCheck: @argcheck

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
        return overnight * construction_factor(discountrate, constructionprofile) * corrected_crf(discountrate, lifetime)
    end
end

# construction_factor
function construction_factor(discountrate, constructionprofile)
    @argcheck constructionprofile isa Union{String, Real} "Construction profile must be a String like \"0.3;0.4;0.3\" or a single real number."
    vc = isa(constructionprofile, String) ? parse.(Float64, split(constructionprofile, ';')) : [Float64(constructionprofile)]
    @argcheck all(x -> x >= 0, vc) "Construction profile must be non-negative."
    total = sum(vc)
    @argcheck isapprox(total, 1.0; rtol=1E-3) "Sum of the construction profile must be close to 1."
    # Accept small rounding errors, but compute with a profile that sums exactly to 1.
    vc = vc ./ total
    cf = sum((vc[y]) * (1 + discountrate)^(length(vc)+1-y) for y in eachindex(vc))
    return cf
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