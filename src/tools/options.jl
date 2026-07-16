"""
    POSY2Options

Paths to input workbooks, economic parameters, and dcopf model switches.
Passed to a Nosy [`Snapshot`](@ref) as `options[:posy]`.
"""

struct POSY2Options
    data_dir::String
    techdata_file::String
    timeseries_file::String
    discountrate::Float64
    co2_price::Float64
    dcopf::Bool
end

POSY2Options(;
    data_dir::String=joinpath(pwd(), "data"),
    techdata_file::String="tech_data.xlsx",
    timeseries_file::String="time_series.xlsx",
    discountrate::Float64=0.05,
    co2_price::Float64=0.0,
    dcopf::Bool=false,
) =
    POSY2Options(data_dir, techdata_file, timeseries_file, discountrate, co2_price, dcopf)

function posy_options(s::Snapshot)
    haskey(s.options, :posy) || throw(ArgumentError("Snapshot.options[:posy] is required."))
    opts = s.options[:posy]
    opts isa POSY2Options || throw(ArgumentError(":posy must be a POSY2Options, got $(typeof(opts))"))
    return opts
end

discountrate(s::Snapshot) = posy_options(s).discountrate
co2_price(s::Snapshot) = posy_options(s).co2_price
dcopf(s::Snapshot) = posy_options(s).dcopf

"""
    applydcopf!(s::Snapshot)

When `POSY2Options.dcopf` is true, add KVL (DC power flow) constraints.
Otherwise do nothing. Call before `Nosy.optimize!`.
"""
function applydcopf!(s::Snapshot)
    dcopf(s) || return nothing
    addkvl!(s)
    return nothing
end
