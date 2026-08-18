# Stochastic Programming

This example shows that investment capacities can be shared across two
snapshots, while operation adapts to each future separately.

- two snapshots in one simulation: High PV CF and Low PV CF
- the same demand in both
- an existing 100 MW CCGT fleet in both, with no new CCGT capacity
- additional PV and battery capacity shared by both snapshots
- a lower PV capacity factor in the Low PV CF snapshot

The two snapshots are solved together with equal probability, so the objective
minimises their average cost.

This is a deliberately simplified example. The same framework can consider
multiple weather time series or snapshots representing other uncertain events.

```jldoctest stochastic; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: @variable, set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
opts = Dict(:posy => Posy2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
))
snap_high_cf = Snapshot(sim, opts)
snap_low_cf = Snapshot(sim, opts)

# Typical daily demand (daytime bump, evening peak)
day = [58.0, 55.0, 53.0, 52.0, 54.0, 60.0, 72.0, 82.0, 88.0, 86.0, 84.0, 82.0, 80.0, 78.0, 77.0, 80.0, 88.0, 96.0, 100.0, 97.0, 90.0, 78.0, 68.0, 62.0]
pv_high_cf = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.05, 0.15, 0.35, 0.6, 0.82, 0.95, 1.0, 0.95, 0.82, 0.6, 0.35, 0.15, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0]
pv_low_cf = 0.8 * pv_high_cf

# Shared PV and battery capacity decisions
@variable(uppermodel(sim), pv_cap >= 0)
@variable(uppermodel(sim), battery_cap >= 0)

# Build both cases
cases = (
    (name="High PV CF", snapshot=snap_high_cf, pv_profile=pv_high_cf),
    (name="Low PV CF", snapshot=snap_low_cf, pv_profile=pv_low_cf),
)
for case in cases
    elec = Node(case.name, EnergyCarrier("electricity $(case.name)", sim), rule=:curtailed, tags=[:electricity])
    co2 = Node("CO2", CO2Carrier("CO2 $(case.name)", sim), rule=:curtailed, tags=[:co2])

    makedemand("Demand", case.name, elec, case.snapshot; profile=repeat(day, 365))
    makeintermittentsource(
        "Solar", "PV", elec, co2, case.snapshot;
        cap=pv_cap,
        profile=repeat(case.pv_profile, 365),
        overnight_cost=500.0,
        lifetime=25,
        construction_profile=1.0,
    )
    makedispatchable(
        "CCGT", "CCGT", elec, co2, case.snapshot;
        cap=100.0,
        fuel_cost=50.0,
    )
    makebatterystorage(
        "Battery", "Battery", elec, case.snapshot;
        cap=battery_cap,
        eff=0.85,
        duration=4.0,
        overnight_cost=200.0,
        lifetime=15,
        construction_profile=1.0,
    )
end

# Minimise the equally weighted expected cost
optimize!([snap_high_cf, snap_low_cf], 0.5 * (cost(snap_high_cf) + cost(snap_low_cf)))
result_high_cf = extract(snap_high_cf)
result_low_cf = extract(snap_low_cf)

# output

Snapshot with 4 component(s) and 1 node(s)

```

No new CCGT capacity can be built: both snapshots use the existing 100 MW
fleet. Additional PV and battery capacity is allowed, and both investment
decisions are shared across the snapshots.

The PV and battery builders share explicit JuMP variables; no extra coupling
constraint is required. Alternatively, a builder can create a capacity
decision in `snap1` with `cap=nothing`, and a builder in `snap2` can reuse its
JuMP `AffExpr`:

```julia
makeintermittentsource(
    "PV", "PV", elec2, co2_2, snap2;
    cap=capacity(snap1, "PV"),
    profile=pv2,
    overnight_cost=500.0,
    lifetime=25,
    construction_profile=1.0,
)
```

This sketch assumes the component in `snap1` is named `"PV"`. Use the complete
generated component name in `capacity`. See [Capacity Semantics](@ref) for the
values accepted by builders' `cap` arguments.

```jldoctest stochastic
julia> capacity(result_high_cf, "CCGT High PV CF"), capacity(result_low_cf, "CCGT Low PV CF")
(100.0, 100.0)

julia> capacity(result_high_cf, "Solar High PV CF"), capacity(result_low_cf, "Solar Low PV CF")
(353.23242938710064, 353.23242938710064)

julia> capacity(result_high_cf, "Battery High PV CF"), capacity(result_low_cf, "Battery Low PV CF")
(226.5140341444653, 226.5140341444653)
```

The High PV CF snapshot needs no CCGT generation. In the Low PV CF snapshot,
the existing CCGT fleet supplies the small amount of demand not met by PV and
storage. The shared battery capacity shifts solar generation in both snapshots.

```jldoctest stochastic
julia> balance(result_high_cf, "CCGT High PV CF", :output, energy; collapse=true, aggregate=true) / 1_000
-1.1681322575896046e-14

julia> balance(result_low_cf, "CCGT Low PV CF", :output, energy; collapse=true, aggregate=true) / 1_000
17.753661255809924

julia> balance(result_high_cf, "Battery High PV CF", :input, energy; collapse=true, aggregate=true) / 1_000
406.30948612660904

julia> balance(result_low_cf, "Battery Low PV CF", :input, energy; collapse=true, aggregate=true) / 1_000
393.0515188138517
```

| | High PV CF | Low PV CF |
|:---|---:|---:|
| CCGT capacity | 100 MW | 100 MW |
| PV capacity | 353 MW | 353 MW |
| Battery capacity | 227 MW | 227 MW |
| CCGT generation | 0 GWh | 18 GWh |
| Battery charging | 406 GWh | 393 GWh |
