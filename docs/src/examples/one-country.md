# One Country

The smallest complete POSY2 study: one electricity node with demand, onshore
wind, and a CCGT. Later examples extend the same pattern of Snapshot, `make*`
builders, optimisation, and result inspection.

Both illustrative workbooks are used on purpose. Demand and wind availability
come from `time_series.xlsx`; wind and CCGT costs come from `tech_data.xlsx`.
Shared names `country1`, `Onwind_country1`, `Onwind`, and `CCGT` show how the
files line up.

```jldoctest one_country; output = false
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

electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Read the synthetic country1 hourly demand.
makedemand("Demand", "country1", electricity, snapshot)

# Read Onwind costs and Onwind_country1 availability from the paired files.
makeintermittentsource("Onshore wind", "Onwind", electricity, co2, snapshot; cap=400.0, weatheryear=2019)
# Read CCGT assumptions; unit_size=0 keeps capacity continuous in this screening example.
makedispatchable("CCGT", "CCGT", electricity, co2, snapshot; maxcap=2_000.0, unit_size=0.0)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 2 node(s)

```

```jldoctest one_country
julia> table(result, capacity)
1×3 DataFrame
 Row │ CCGT country1  Demand country1  Onshore wind country1
     │ Float64        Float64          Float64
─────┼───────────────────────────────────────────────────────
   1 │       927.129              0.0                  400.0
```

Wind is fixed at the stated 400 MW; the CCGT capacity is chosen to cover the
residual after wind. Write the solved result with
[`printsnapshot`](@ref) if you want the standard Excel report:

```julia
printsnapshot(result, "one-country.xlsx")
```

That creates `results/one-country.xlsx` with annual indicators, time series,
and price-duration curves. Different filenames make it easy to compare
scenarios. Renaming the node or technology changes which workbook columns
POSY2 reads.
