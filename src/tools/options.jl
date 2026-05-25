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
    return s.options[:posy]::POSY2Options
end

discountrate(s::Snapshot) = posy_options(s).discountrate
co2_price(s::Snapshot) = posy_options(s).co2_price
