"""
    POSY2Options(; data_dir=joinpath(pwd(), "data"),
        techdata_file="tech_data.xlsx", timeseries_file="time_series.xlsx",
        tech_mode=:excel, timeseries_mode=:excel,
        discountrate=0.05, co2_price=0.0, dcopf=false)

Configure POSY2 input workbooks, economic assumptions, and the optional DC
power-flow formulation. Pass the resulting object to a Nosy snapshot as
`Snapshot(sim, Dict(:posy => options))`.

Fields:

- `data_dir`: directory containing the Excel workbooks.
- `techdata_file`: technology-parameter workbook filename.
- `timeseries_file`: hourly time-series workbook filename.
- `tech_mode`: `:excel` to fill missing technology arguments from the workbook,
  or `:arguments` to require them explicitly.
- `timeseries_mode`: `:excel` to fill missing profiles from the workbook, or
  `:arguments` to require them explicitly.
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
    tech_mode::Symbol
    timeseries_mode::Symbol
    discountrate::Float64
    co2_price::Float64
    dcopf::Bool

    function POSY2Options(data_dir::String,
                          techdata_file::String,
                          timeseries_file::String,
                          tech_mode::Symbol,
                          timeseries_mode::Symbol,
                          discountrate::Float64,
                          co2_price::Float64,
                          dcopf::Bool)
        tech_mode in (:excel, :arguments) ||
            throw(ArgumentError("tech_mode must be :excel or :arguments, got $(repr(tech_mode))"))
        timeseries_mode in (:excel, :arguments) ||
            throw(ArgumentError("timeseries_mode must be :excel or :arguments, got $(repr(timeseries_mode))"))
        new(data_dir, techdata_file, timeseries_file, tech_mode, timeseries_mode,
            discountrate, co2_price, dcopf)
    end
end

POSY2Options(;
    data_dir::String=joinpath(pwd(), "data"),
    techdata_file::String="tech_data.xlsx",
    timeseries_file::String="time_series.xlsx",
    tech_mode::Symbol=:excel,
    timeseries_mode::Symbol=:excel,
    discountrate::Float64=0.05,
    co2_price::Float64=0.0,
    dcopf::Bool=false,
) =
    POSY2Options(data_dir, techdata_file, timeseries_file, tech_mode, timeseries_mode,
                 discountrate, co2_price, dcopf)

# Preserve the original positional constructor for downstream code.
POSY2Options(data_dir::String,
             techdata_file::String,
             timeseries_file::String,
             discountrate::Float64,
             co2_price::Float64,
             dcopf::Bool) =
    POSY2Options(data_dir, techdata_file, timeseries_file, :excel, :excel,
                 discountrate, co2_price, dcopf)

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

"""Return the configured technology-input mode (`:excel` or `:arguments`)."""
tech_mode(s::Snapshot) = posy_options(s).tech_mode

"""Return the configured time-series-input mode (`:excel` or `:arguments`)."""
timeseries_mode(s::Snapshot) = posy_options(s).timeseries_mode

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
