"""
    Posy2Options(; data_dir=joinpath(pwd(), "data"),
        techdata_file="tech_data.xlsx", timeseries_file="time_series.xlsx",
        tech_mode=:arguments, timeseries_mode=:arguments,
        discount_rate=0.05, co2_price=0.0)

Configure Posy2 input workbooks and economic assumptions. Pass the resulting
object to a Nosy snapshot as `Snapshot(sim, Dict(:posy => options))`.

Fields:

- `data_dir`: directory containing the input workbooks.
- `techdata_file`: technology-parameter workbook filename.
- `timeseries_file`: hourly time-series workbook filename.
- `tech_mode`: `:arguments` (default) to use documented neutral defaults and
  require structural values explicitly, or `:excel` to fill omitted technology
  arguments from the workbook.
- `timeseries_mode`: `:arguments` (default) to use documented neutral profiles
  and require structural profiles explicitly, or `:excel` to fill omitted
  profiles from the workbook.
- `discount_rate`: real discount rate used to annualise investment and
  decommissioning costs.
- `co2_price`: carbon price applied by emitting component builders.

DC power flow is not configured here: call [`applydcopf!`](@ref) on the
snapshot when a study needs KVL constraints.
"""
struct Posy2Options
    data_dir::String
    techdata_file::String
    timeseries_file::String
    tech_mode::Symbol
    timeseries_mode::Symbol
    discount_rate::Float64
    co2_price::Float64

    function Posy2Options(data_dir::String,
                          techdata_file::String,
                          timeseries_file::String,
                          tech_mode::Symbol,
                          timeseries_mode::Symbol,
                          discount_rate::Float64,
                          co2_price::Float64)
        tech_mode in (:excel, :arguments) ||
            throw(ArgumentError("tech_mode must be :excel or :arguments, got $(repr(tech_mode))"))
        timeseries_mode in (:excel, :arguments) ||
            throw(ArgumentError("timeseries_mode must be :excel or :arguments, got $(repr(timeseries_mode))"))
        new(data_dir, techdata_file, timeseries_file, tech_mode, timeseries_mode,
            discount_rate, co2_price)
    end
end

Posy2Options(;
    data_dir::String=joinpath(pwd(), "data"),
    techdata_file::String="tech_data.xlsx",
    timeseries_file::String="time_series.xlsx",
    tech_mode::Symbol=:arguments,
    timeseries_mode::Symbol=:arguments,
    discount_rate::Float64=0.05,
    co2_price::Float64=0.0,
) =
    Posy2Options(data_dir, techdata_file, timeseries_file, tech_mode, timeseries_mode,
                 discount_rate, co2_price)

"""
    posy_options(s::Snapshot)

Return the [`Posy2Options`](@ref) stored in `s.options[:posy]`.

Throw an `ArgumentError` when the entry is missing or is not a
`Posy2Options` object.
"""
function posy_options(s::Snapshot)
    haskey(s.options, :posy) || throw(ArgumentError("Snapshot.options[:posy] is required."))
    opts = s.options[:posy]
    opts isa Posy2Options || throw(ArgumentError(":posy must be a Posy2Options, got $(typeof(opts))"))
    return opts
end

"""
    discount_rate(s::Snapshot)

Return the discount rate configured in the snapshot's [`Posy2Options`](@ref).
"""
discount_rate(s::Snapshot) = posy_options(s).discount_rate

"""
    co2_price(s::Snapshot)

Return the carbon price configured in the snapshot's [`Posy2Options`](@ref).
"""
co2_price(s::Snapshot) = posy_options(s).co2_price

"""Return the configured technology-input mode (`:excel` or `:arguments`)."""
tech_mode(s::Snapshot) = posy_options(s).tech_mode

"""Return the configured time-series-input mode (`:excel` or `:arguments`)."""
timeseries_mode(s::Snapshot) = posy_options(s).timeseries_mode

