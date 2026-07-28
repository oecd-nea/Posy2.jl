# Dispatchable Generation

This page tours [`makenuclear`](@ref) and [`makedispatchable`](@ref) together:
capacity expansion under workbook costs, and nuclear fuel reloading under unit
commitment. Flat 100 MW demand keeps the dispatch readable. Both plants use
`maxcap` rather than a fixed `cap`, so the optimiser chooses how much to build.

Technology costs and multi-year profiles come from `tech_data.xlsx`
(`tech_mode=:excel`). Reloading is not active in that workbook by default, so
the nuclear plant sets `uc=true` with explicit
`reload_fraction_per_year`, `reload_duration`, and `reloadmask`. Reloading
needs a full-year mesh. `integeruc=true` keeps commitment on/off so the reload
window stays sharp.

```jldoctest dispatchable_generation; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(POSY2), "data")
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="unused.xlsx",
    tech_mode=:excel,
    timeseries_mode=:arguments,
    discountrate=0.05,
)))

electricity = Node("COUNTRY", EnergyCarrier("electricity COUNTRY", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "COUNTRY", electricity, snapshot; coeff=0.0, yearlyconstant=100.0 * 8760)

makenuclear(
    "Nuclear", "Nuclear", electricity, co2, snapshot;
    maxcap=200.0,
    unit_size=100.0,
    uc=true,
    integeruc=true,
    reload_fraction_per_year=1.0,
    reload_duration=48.0,
    reloadmask=720,
    min_power=0.5,
    min_uptime=24.0,
    min_downtime=24.0,
    startup_duration=1.0,
    shutdown_duration=1.0,
    no_load_cost=0.0,
    startup_cost=0.0,
)

makedispatchable(
    "CCGT", "CCGT", electricity, co2, snapshot;
    maxcap=200.0,
    unit_size=0.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 2 node(s)

```

The build-out is 100 MW nuclear plus 100 MW CCGT. Nuclear is cheaper for the
flat year, but the required reload outage needs a second plant while it is
offline:

```jldoctest dispatchable_generation
julia> table(result, capacity)
1×3 DataFrame
 Row │ CCGT COUNTRY  Demand COUNTRY  Nuclear COUNTRY
     │ Float64       Float64         Float64
─────┼───────────────────────────────────────────────
   1 │        100.0             0.0            100.0
```

Allowed reload starts follow `reloadmask`; the optimiser picks which allowed
window to use. `findfirst(iszero, nuclear)` and `findlast(iszero, nuclear)`
return the first and last hours of that outage. Slicing a few steps around
those indices shows the one-hour 50 MW ramp hand-off with the CCGT:

```jldoctest dispatchable_generation
julia> nuclear = balance(result, "Nuclear COUNTRY", :output, energy; collapse=false, aggregate=true);

julia> ccgt = balance(result, "CCGT COUNTRY", :output, energy; collapse=false, aggregate=true);

julia> i0, i1 = findfirst(iszero, nuclear), findlast(iszero, nuclear)
(8642, 8700)

julia> nuclear[i0-2:i0+1]
4-element Vector{Float64}:
 100.0
  50.0
   0.0
   0.0

julia> ccgt[i0-2:i0+1]
4-element Vector{Float64}:
   0.0
  50.0
 100.0
 100.0

julia> nuclear[i1-1:i1+2]
4-element Vector{Float64}:
   0.0
   0.0
  50.0
 100.0

julia> ccgt[i1-1:i1+2]
4-element Vector{Float64}:
 100.0
 100.0
  50.0
   0.0

julia> count(iszero, nuclear)
59
```

Nuclear is offline for 59 hours in that window; the CCGT covers the flat demand
then. Workbook-derived fixed costs (annualised) scale with the chosen
capacities. `costs(result)` reports every objective tag; the investment and
decommissioning columns are the ones that matter here:

```jldoctest dispatchable_generation
julia> costs(result)[:, [:component, :investment, :decommissioning]]
4×3 DataFrame
 Row │ component        investment  decommissioning
     │ String           Float64     Float64
─────┼──────────────────────────────────────────────
   1 │ CCGT COUNTRY      6.52821e6    66818.5
   2 │ Demand COUNTRY    0.0              0.0
   3 │ Nuclear COUNTRY   2.07056e7        1.10394e5
   4 │ all               2.72338e7   177212.0
```
