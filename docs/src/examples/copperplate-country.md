# Copperplate Country

A copperplate model represents the whole country with one electricity node.
Every generator and every demand is connected to that node, so electricity can
move anywhere inside the country without a transmission limit or loss.

This first example deliberately uses both illustrative workbooks. Demand and
onshore-wind availability come from `time_series.xlsx`; the wind and CCGT
technology assumptions come from `tech_data.xlsx`. The shared names
`country1`, `Onwind_country1`, `Onwind`, and `CCGT` show how the files fit
together.

```jldoctest copperplate_country; output = false
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
        tech_mode=:excel,
        timeseries_mode=:excel,
        discountrate=0.05,
        co2_price=0.0,
    )),
)

electricity = Node(
    "country1",
    EnergyCarrier("electricity country1", sim),
    rule=:curtailed,
    evalprice=true,
    tags=[:electricity],
)
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Read the synthetic country1 hourly demand.
makedemand(
    "Demand", "country1", electricity, snapshot,
)

# Read Onwind costs and Onwind_country1 availability from the paired files.
makeintermittentsource(
    "Onshore wind", "Onwind", electricity, co2, snapshot;
    cap=400.0,
    weatheryear=2019,
)

# Read CCGT assumptions and let POSY2 choose the required backup capacity.
makedispatchable(
    "CCGT", "CCGT", electricity, co2, snapshot;
    maxcap=2_000.0,
    # Disable discrete unit sizing in this screening example.
    unit_size=0.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 2 node(s)

```

```jldoctest copperplate_country
julia> capacity(result, "Onshore wind country1")
400.0

julia> demand_energy = balance(result, "Demand country1", :input, energy; collapse=true, aggregate=true);

julia> supplied_energy = balance(result, "Onshore wind country1", :output, energy; collapse=true, aggregate=true) + balance(result, "CCGT country1", :output, energy; collapse=true, aggregate=true);

julia> isapprox(supplied_energy, demand_energy; atol=1e-6)
true
```

The extracted result can also be written to POSY2's standard post-processing
workbook:

```julia
printsnapshot(result, "copperplate-country.xlsx")
```

This creates `results/copperplate-country.xlsx` with annual system indicators,
time series, and price-duration curves. Supplying distinct filenames makes it
convenient to compare the outputs from several example scenarios.

This is a data-contract example as well as a copperplate model: changing the
node name or technology name changes the time-series column POSY2 requests.
The copperplate approximation is useful for screening technology mixes and
whole-country balances. It is usually not the best representation for a
transmission study: it produces one national electricity price and cannot
show internal congestion, grid losses, regional scarcity, redispatch, or the
value of reinforcing a particular corridor. Split the country into several
nodes when those effects matter.
