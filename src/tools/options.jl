"""
    POSY2Options(; data_dir=joinpath(pwd(), "data"),
        techdata_file="tech_data.xlsx", timeseries_file="time_series.xlsx",
        discountrate=0.05, co2_price=0.0, dcopf=false)

Configure POSY2 input workbooks, economic assumptions, and the optional DC
power-flow formulation. Pass the resulting object to a Nosy snapshot as
`Snapshot(sim, Dict(:posy => options))`.

Fields:

- `data_dir`: directory containing the two Excel workbooks.
- `techdata_file`: technology-parameter workbook filename.
- `timeseries_file`: hourly time-series workbook filename.
- `discountrate`: real discount rate used to annualise investment and
  decommissioning costs.
- `co2_price`: carbon price applied by emitting component builders.
- `dcopf`: whether [`applydcopf!`](@ref) should add KVL constraints before
  optimisation.
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

"""
    posy_options(s::Snapshot)

Return the [`POSY2Options`](@ref) stored in `s.options[:posy]`.

Throw an `ArgumentError` when the entry is missing or is not a
`POSY2Options` object.
"""
function posy_options(s::Snapshot)
    haskey(s.options, :posy) || throw(ArgumentError("Snapshot.options[:posy] is required."))
    opts = s.options[:posy]
    opts isa POSY2Options || throw(ArgumentError(":posy must be a POSY2Options, got $(typeof(opts))"))
    return opts
end

"""
    discountrate(s::Snapshot)

Return the discount rate configured in the snapshot's [`POSY2Options`](@ref).
"""
discountrate(s::Snapshot) = posy_options(s).discountrate

"""
    co2_price(s::Snapshot)

Return the carbon price configured in the snapshot's [`POSY2Options`](@ref).
"""
co2_price(s::Snapshot) = posy_options(s).co2_price

"""
    dcopf(s::Snapshot)

Return whether DC power flow is enabled in the snapshot's
[`POSY2Options`](@ref).
"""
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
