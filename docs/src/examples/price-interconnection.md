# Price Interconnection

This example compares a domestic CCGT with imports from an external market via
[`makepricelink`](@ref). The model imports when the external `spot_price`
plus `transaction_cost` is below the CCGT `fuel_cost`.

Unlike [`maketransmissionlink`](@ref), that market is not an explicit node.
The single `"country2"` argument names the component (`"country2_country1"`), the
reported neighbour, and the workbook columns the spot-price and transfer series
are read from; pass `neighbor` or `neighbor_column` to separate those roles.
Import capacity is set large on purpose (`import_cap=10_000`) and export is
off (`export_cap=0`), so the import/CCGT choice depends on price, not on
transfer limits.

```jldoctest price_interconnection; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(
    sim,
    Dict(:posy => Posy2Options(
        data_dir=example_data_dir,
        techdata_file="tech_data.xlsx",
        timeseries_file="time_series.xlsx",
        tech_mode=:arguments,
        timeseries_mode=:excel,
    )),
)

# Domestic electricity node and CO2 sink
# evalprice=true stores electricity node dual prices for reporting.
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:default, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Flat 100 MW demand
makedemand("Demand", "country1", electricity, snapshot; profile_multiplier=0.0, annual_flat_demand=100.0 * 8760)

# Domestic 100 MW CCGT
makedispatchable(
    "CCGT", electricity, snapshot; co2_node=co2, tech_column="CCGT",
    cap=100.0,
    fuel_cost=47.06,
)

# Priced import from "country2" (spot series); Large import capacity, export capacity off
makepricelink(
    "country2", electricity, snapshot;
    import_cap=10_000.0, export_cap=0.0, transaction_cost=1.0,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 1 node(s)

```

A sample week shows how meeting demand switches between imports and the
domestic CCGT as `spot_price + transaction_cost` moves relative to the CCGT
fuel cost. It plots `dualprice` next to that import cost and the fuel line,
with import and CCGT dispatch underneath.

![Domestic dualprice versus import cost and CCGT dispatch over one week](../assets/price-interconnection-week.svg)

Over the full year, both imports and the domestic CCGT contribute to meeting
demand (`376400 + 499600 = 876000 MWh`):

```jldoctest price_interconnection
julia> balance(result, "country2_country1", :output, energy; collapse=true, aggregate=true)
376400.0

julia> balance(result, "CCGT country1", :output, energy; collapse=true, aggregate=true)
499600.0
```
