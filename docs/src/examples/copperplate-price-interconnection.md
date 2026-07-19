# Copperplate Country with a Priced Neighbour

[`makepriceinterco`](@ref) represents trade with a neighbouring market without
building that neighbour's generators and demands. POSY2 reads the neighbour's
hourly spot price and both directional transfer multipliers from the time-series
workbook.

```jldoctest copperplate_price; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(POSY2), "data")
snapshot = Snapshot(
    sim,
    Dict(:posy => POSY2Options(
        data_dir=example_data_dir,
        techdata_file="tech_data.xlsx",
        timeseries_file="time_series.xlsx",
        tech_mode=:arguments,
        timeseries_mode=:excel,
    )),
)

electricity = Node(
    "country1",
    EnergyCarrier("electricity country1", sim),
    rule=:default,
    evalprice=true,
    tags=[:electricity],
)

makedemand(
    "Demand", "unused", electricity, snapshot;
    coeff=0.0,
    yearlyconstant=100.0 * 8760,
)
makepriceinterco(
    "country2",
    electricity,
    10_000.0, # nominal import capacity before hourly multipliers
    0.0,   # nominal export capacity
    snapshot;
    transactioncost=1.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 2 component(s) and 1 node(s)

```

```jldoctest copperplate_price
julia> balance(result, "IC_country2_country1", :output, energy; collapse=true, aggregate=true)
876000.0
```

The local country imports its entire 100 MW demand. `mcap` and `xcap` are
nominal import and export capacities; the workbook columns `country2>country1` and
`country1>country2` multiply them hour by hour. The `country2` `spot_price` column sets
the import cost and export revenue. Use this boundary when the neighbour is an
exogenous market; use [`makenodeinterco`](@ref) when both countries should be
optimised inside the same model.
