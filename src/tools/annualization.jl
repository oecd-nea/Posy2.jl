using ArgCheck: @argcheck

"""
    eac(overnight_cost::Real, discount_rate::Real, lifetime, construction_profile)
Return the annualized investment cost in function of the overnight cost, the discount rate, the lifetime and the construction profile.
The effects are the following:
  * total cost (financing taking construction time into account + overnight cost)
  * annualization via corrected CRF (so that operation starts right after construction, no white year)

Units: `overnight_cost` is a cost per unit of capacity and the result is that cost per unit of capacity per year.
Builders take `overnight_cost` in currency per kW and multiply it by 1000 before calling `eac`, so a direct
call takes currency per MW and returns currency per MW per year.
`discount_rate` is a fraction per year, `lifetime` is a number of years, and `construction_profile` is a
number or a vector of yearly shares summing to 1.
"""
function eac(overnight_cost::Real, discount_rate::Real, lifetime, construction_profile)
    if ismissing(construction_profile)
        throw(ArgumentError("construction profile is missing"))
    else
        annualized = iszero(discount_rate) ? (1 / lifetime) : corrected_crf(discount_rate, lifetime)
        return overnight_cost * construction_factor(discount_rate, construction_profile) * annualized
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

function construction_factor(discount_rate::Real, construction_profile)
    vc = profile_shares(construction_profile, "construction profile")
    return sum(vc[y] * (1 + discount_rate)^(length(vc) + 1 - y) for y in eachindex(vc))
end

function decommissioning_factor(discount_rate::Real, decommissioning_profile)
    shares = profile_shares(decommissioning_profile, "decommissioning profile")
    return sum(share / (1 + discount_rate)^(year - 1) for (year, share) in enumerate(shares))
end

#version of capital recovery factor that does not consider year 0 as a white year
corrected_crf(discount_rate, lifetime) = discount_rate / (1 + discount_rate) / (1 - (1 + discount_rate)^(-lifetime))

"""
    decom_cost(overnight_cost::Real, deco_ratio, lifetime, discount_rate::Real, decommissioning_profile)
Return the annualized decommissioning cost in function of the overnight cost, the decommissioning ratio, the lifetime, the discount rate and the decommissioning profile.
The effects are the following:
  * total decommissioning cost (overnight_cost * decommissioning ratio)
  * discounting to the end of lifetime and payment timing via decommissioning profile
  * annualization via corrected CRF over the operating lifetime
"""
function decom_cost(overnight_cost::Real, deco_ratio, lifetime, discount_rate::Real, decommissioning_profile)
    if ismissing(deco_ratio)
        throw(ArgumentError("decommissioning ratio is missing"))
    end
    if ismissing(decommissioning_profile)
        throw(ArgumentError("decommissioning profile is missing"))
    end
    total_decommissioning_cost = overnight_cost * deco_ratio
    lifetime_discount = iszero(discount_rate) ? 1.0 : (1 + discount_rate)^(-lifetime)
    present_value = total_decommissioning_cost * lifetime_discount * decommissioning_factor(discount_rate, decommissioning_profile)
    annualized_cost = iszero(discount_rate) ? (1 / lifetime) : corrected_crf(discount_rate, lifetime)
    return present_value * annualized_cost
end
