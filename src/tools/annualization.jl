using ArgCheck: @argcheck

"""
    eac(overnight::Number, discountrate::Number, lifetime, constructionprofile)
Return the annualized investment cost in function of the overnight cost, the discount rate, the lifetime and the construction profile.
The effects are the following:
  * total cost (financing taking construction time into account + overnight)
  * annualization via corrected CRF (so that operation starts right after construction, no white year)
"""
function eac(overnight::Number, discountrate::Number, lifetime, constructionprofile)
    if ismissing(constructionprofile)
        throw(ArgumentError("construction profile is missing"))
    else
        annualized = iszero(discountrate) ? (1 / lifetime) : corrected_crf(discountrate, lifetime)
        return overnight * construction_factor(discountrate, constructionprofile) * annualized
    end
end

# construction_factor
function construction_factor(discountrate::Number, constructionprofile)
    @argcheck constructionprofile isa Union{String, Number} "Construction profile must be a String like \"0.3;0.4;0.3\" or a single number."
    vc = isa(constructionprofile, String) ? parse.(Float64, split(constructionprofile, ';')) : [Float64(constructionprofile)]
    @argcheck all(x -> x >= 0, vc) "Construction profile must be non-negative."
    total = sum(vc)
    @argcheck isapprox(total, 1.0; rtol=1E-3) "Sum of the construction profile must be close to 1."
    # Accept small rounding errors, but compute with a profile that sums exactly to 1.
    vc = vc ./ total
    cf = sum((vc[y]) * (1 + discountrate)^(length(vc)+1-y) for y in eachindex(vc))
    return cf
end

function decommissioning_factor(discountrate::Number, decommissionprofile)
    @argcheck decommissionprofile isa Union{String, Number} "Decommissioning profile must be a String like \"0.3;0.4;0.3\" or a single number."
    shares = isa(decommissionprofile, String) ? parse.(Float64, split(decommissionprofile, ';')) : [Float64(decommissionprofile)]
    @argcheck all(x -> x >= 0, shares) "Decommissioning profile must be non-negative."
    total = sum(shares)
    @argcheck isapprox(total, 1.0; rtol=1E-3) "Sum of the decommissioning profile must be close to 1."
    # Accept small rounding errors, but compute with a profile that sums exactly to 1.
    shares = shares ./ total
    return sum(share / (1 + discountrate)^(year - 1) for (year, share) in enumerate(shares))
end

#version of capital recovery factor that does not consider year 0 as a white year
corrected_crf(discountrate, lifetime) = discountrate / (1 + discountrate) / (1 - (1 + discountrate)^(-lifetime))

"""
    decom_cost(overnight::Number, deco_ratio, lifetime, discountrate::Number, decommissionprofile)
Return the annualized decommissioning cost in function of the overnight cost, the decommissioning ratio, the lifetime, the discount rate and the decommissioning profile.
The effects are the following:
  * total decommissioning cost (overnight * decommissioning ratio)
  * discounting to the end of lifetime and payment timing via decommissioning profile
  * annualization via corrected CRF over the operating lifetime
"""
function decom_cost(overnight::Number, deco_ratio, lifetime, discountrate::Number, decommissionprofile)
    if ismissing(deco_ratio)
        throw(ArgumentError("decommissioning ratio is missing"))
    end
    if ismissing(decommissionprofile)
        throw(ArgumentError("decommissioning profile is missing"))
    end
    total_decommissioning_cost = overnight * deco_ratio
    lifetime_discount = iszero(discountrate) ? 1.0 : (1 + discountrate)^(-lifetime)
    present_value = total_decommissioning_cost * lifetime_discount * decommissioning_factor(discountrate, decommissionprofile)
    annualized_cost = iszero(discountrate) ? (1 / lifetime) : corrected_crf(discountrate, lifetime)
    return present_value * annualized_cost
end
