# Pumped Storage

Pumped storage has both grid-charging and turbine capacities but no natural
inflow. Unlike the [Hydro Reservoir](hydro-reservoir.md) pattern, the plant
can lift water with electricity and generate later.
[`makehydroreservoir`](@ref) still builds the plant; the difference is a
positive charging capacity and zero inflow.

The study pairs flat demand with workbook PV
([`makeintermittentsource`](@ref) reading `PV_country1` from
`profiles_2019`), pumped hydro, and an oil plant. Daytime solar surplus
charges the reservoir; the turbine returns energy later. Oil covers hours
that storage cannot.

```jldoctest pumped_storage; output = false
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
    timeseries_file="time_series.xlsx",
    tech_mode=:arguments,
    timeseries_mode=:excel,
)))

electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "country1", electricity, snapshot; coeff=0.0, yearlyconstant=50.0 * 8760)

makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=200.0,
    weatheryear=2019,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=25,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=0.0,
    co2_emission=0.0,
)

makedispatchable(
    "Oil", "Oil", electricity, co2, snapshot;
    cap=50.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=68.24,
    co2_emission=0.0,
    unit_size=0.0,
)

makehydroreservoir(
    "Pumped hydro",
    "Hydro res",
    "country1",
    electricity,
    50.0,     # turbine capacity
    75.0,     # pumping capacity
    12_000.0, # reservoir energy capacity
    0.0,      # no natural inflow
    snapshot;
    simplified=false,
    eff=0.8,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    om_var_cost=0.0,
    decommissioning=0.0,
    lifetime=80,
    construction_profile=1.0,
    decommissioning_profile=1.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

```jldoctest pumped_storage
julia> pump = balance(result, "Pumped hydro country1", :input, energy; collapse=false, aggregate=true);

julia> turbine = balance(result, "Pumped hydro country1", :output, energy; collapse=false, aggregate=true);

julia> level = balance(result, "Pumped hydro country1", :level, energy; collapse=false, aggregate=true);

julia> balance(result, "Pumped hydro country1", :input, energy; collapse=true, aggregate=true)
100260.49119999993

julia> balance(result, "Pumped hydro country1", :output, energy; collapse=true, aggregate=true)
80208.39296000007

julia> round(balance(result, "Pumped hydro country1", :output, energy; collapse=true, aggregate=true) /
            balance(result, "Pumped hydro country1", :input, energy; collapse=true, aggregate=true); digits=2)
0.8

julia> maximum(pump), maximum(turbine)
(75.0, 50.0)

julia> balance(result, "Oil country1", :output, energy; collapse=true, aggregate=true)
191777.68064000004
```

Pumping and generation recover the 80% round-trip efficiency, and the hourly
peaks hit the 75 MW pumping and 50 MW turbine ratings. Oil still covers a large
residual because storage only moves a share of the PV surplus. The reservoir
`level` rises while pumping and falls while generating;
`argmax(level)` marks the yearly peak:

```jldoctest pumped_storage
julia> peak = argmax(level)
3762

julia> level[peak-5:peak+5]
11-element Vector{Float64}:
 278.49046
 338.49046
 398.49046
 454.69894
 494.00358
 505.93434
 489.05984
 448.47554
 398.60034
 348.60034
 298.60034

julia> maximum(level)
505.93434
```

Natural inflow reservoirs normally use `cap_charging=0` and a positive or
workbook-backed inflow; pumped storage uses the opposite pair on the same
[`makehydroreservoir`](@ref) builder.

