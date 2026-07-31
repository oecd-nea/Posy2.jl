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

Wind capacity is fixed by the builder at 400 MW. The CCGT is free to expand
up to `maxcap`, and the optimiser installs about 927 MW so that residual demand
after wind can still be met in every hour.

That capacity choice shows up in the hourly dispatch. Over a sample week from
the solved year, wind (bottom) and CCGT (top) stack to the black demand line:
when wind is strong the CCGT layer shrinks; when wind is weak the CCGT fills
the residual, up to the capacity above.

![Stacked wind and CCGT versus demand over one week](../assets/one-country-week.svg)

Because the CCGT covers most of the residual energy, workbook fuel and variable
O&M on that plant dominate the objective. Wind costs are mostly annualised
investment plus variable O&M on its generation:

```jldoctest one_country
julia> costs(result)[:, [:component, :investment, :fuel, :total]]
4×4 DataFrame
 Row │ component              investment  fuel       total
     │ String                 Float64     Float64    Float64
─────┼─────────────────────────────────────────────────────────
   1 │ CCGT country1           6.05249e7  2.46745e8  3.44539e8
   2 │ Demand country1         0.0        0.0        0.0
   3 │ Onshore wind country1   4.08402e7  0.0        5.71922e7
   4 │ all                     1.01365e8  2.46745e8  4.01731e8
```

Write the solved result with [`printsnapshot`](@ref) if you want the standard
Excel report:

```jldoctest one_country
julia> printsnapshot(result, "one-country.xlsx")
```

That creates `results/one-country.xlsx` with annual indicators, time series,
and price-duration curves. Different filenames make it easy to compare
scenarios. Renaming the node or technology changes which workbook columns
POSY2 reads.
