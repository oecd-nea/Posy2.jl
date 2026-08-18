using ArgCheck: @argcheck

"""
    eac(overnight::Real, discountrate::Real, lifetime, constructionprofile)
Return the annualized investment cost in function of the overnight cost, the discount rate, the lifetime and the construction profile.
The effects are the following:
  * total cost (financing taking construction time into account + overnight)
  * annualization via corrected CRF (so that operation starts right after construction, no white year)

Units: `overnight` is a cost per unit of capacity and the result is that cost per unit of capacity per year.
Builders take `overnight_cost` in currency per kW and multiply it by 1000 before calling `eac`, so a direct
call takes currency per MW and returns currency per MW per year.
`discountrate` is a fraction per year, `lifetime` is a number of years, and `constructionprofile` is a
number or a vector of yearly shares summing to 1.
"""
function eac(overnight::Real, discountrate::Real, lifetime, constructionprofile)
    if ismissing(constructionprofile)
        throw(ArgumentError("construction profile is missing"))
    else
        annualized = iszero(discountrate) ? (1 / lifetime) : corrected_crf(discountrate, lifetime)
        return overnight * construction_factor(discountrate, constructionprofile) * annualized
    end
end

"""
    profile_shares(profile, name::String)
Return the yearly cost shares of `profile` as a fresh vector summing exactly to 1.
`profile` is a single number (whole cost in one year) or one share per year, e.g. `[1/3, 1/3, 1/3]`.
"""
function profile_shares(profile, name::String)
    @argcheck profile isa Union{Real,AbstractVector{<:Real}} "$name must be a number or a vector of yearly shares, such as [1/3, 1/3, 1/3]."
    shares = profile isa Real ? [Float64(profile)] : Float64.(profile)
    @argcheck !isempty(shares) "$name must cover at least one year."
    @argcheck all(isfinite, shares) "$name must be finite."
    @argcheck all(>=(0), shares) "$name must be non-negative."
    total = sum(shares)
    @argcheck isapprox(total, 1.0; rtol=1E-3) "Sum of the $name must be close to 1."
    # Accept small rounding errors, but compute with a profile that sums exactly to 1.
    return shares ./ total
end

function construction_factor(discountrate::Real, constructionprofile)
    vc = profile_shares(constructionprofile, "construction profile")
    return sum(vc[y] * (1 + discountrate)^(length(vc) + 1 - y) for y in eachindex(vc))
end

function decommissioning_factor(discountrate::Real, decommissionprofile)
    shares = profile_shares(decommissionprofile, "decommissioning profile")
    return sum(share / (1 + discountrate)^(year - 1) for (year, share) in enumerate(shares))
end

#version of capital recovery factor that does not consider year 0 as a white year
corrected_crf(discountrate, lifetime) = discountrate / (1 + discountrate) / (1 - (1 + discountrate)^(-lifetime))

"""
    decom_cost(overnight::Real, deco_ratio, lifetime, discountrate::Real, decommissionprofile)
Return the annualized decommissioning cost in function of the overnight cost, the decommissioning ratio, the lifetime, the discount rate and the decommissioning profile.
The effects are the following:
  * total decommissioning cost (overnight * decommissioning ratio)
  * discounting to the end of lifetime and payment timing via decommissioning profile
  * annualization via corrected CRF over the operating lifetime
"""
function decom_cost(overnight::Real, deco_ratio, lifetime, discountrate::Real, decommissionprofile)
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
