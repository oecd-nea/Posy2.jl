"""
    POSY2Options

Paths to input workbooks and economy parameters.
Passed to a Nosy [`Snapshot`](@ref) as `options[:posy]`.
"""

struct POSY2Options
    data_dir::String
    techdata_file::String
    timeseries_file::String
    discountrate::Float64
    co2_price::Float64
end

POSY2Options(;
    data_dir::String=joinpath(pwd(), "data"),
    techdata_file::String="tech_data.xlsx",
    timeseries_file::String="time_series.xlsx",
    discountrate::Float64=0.05,
    co2_price::Float64=0.0,
) =
    POSY2Options(data_dir, techdata_file, timeseries_file, discountrate, co2_price)

function posy_options(s::Snapshot)
    haskey(s.options, :posy) || throw(ArgumentError("Snapshot.options[:posy] is required."))
    opts = s.options[:posy]
    opts isa POSY2Options || throw(ArgumentError(":posy must be a POSY2Options, got $(typeof(opts))"))
    return opts
end

discountrate(s::Snapshot) = posy_options(s).discountrate
co2_price(s::Snapshot) = posy_options(s).co2_price

function dcopf(s::Snapshot)
    haskey(s.options, :dcopf) || return false
    v = s.options[:dcopf]
    v isa Bool || throw(ArgumentError(":dcopf must be Bool, got $(typeof(v))"))
    return v
end

"""
    applydcopf!(s::Snapshot)

When `Snapshot.options[:dcopf]` is true, add KVL (DC power flow) constraints.
Otherwise do nothing. Call before `Nosy.optimize!`.
"""
function applydcopf!(s::Snapshot)
    dcopf(s) || return nothing
    addkvl!(s)
    return nothing
end
