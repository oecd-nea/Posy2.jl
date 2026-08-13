# Electric Vehicles

This example compares smart charging and vehicle-to-grid on the same fleet
and driving need: how grid charge, discharge, and oil generation change.

[`makeEV`](@ref) picks that behaviour with exactly one of three flags:
`fixed_profile`, `smart_charging`, or `vehicle_to_grid`. This page keeps the
same demand, PV, oil backup, and driving need, and only flips the flag:
`smart_charging=true` first, then `vehicle_to_grid=true`.

The setup is:

- country1 demand and 1500 MW of PV
- a fleet whose annual driving energy is 50,000 MWh
- oil backup that covers residual load

The driving follows a fixed hourly profile. With smart charging the optimiser only
chooses when to fill the battery. With V2G it also chooses when to sell power
back to the node.

## Smart charging

Cars take power from the grid and give it up only as driving. Charge hours are
free, so the optimiser charges when the dual is low to cover later driving.
With no grid discharge, annual charge matches annual driving: only the timing
changes.

```jldoctest electric_vehicles_smart; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:arguments,
    timeseries_mode=:excel,
)))

# Electricity node (evalprice for dualprice) and CO2 sink
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Hourly electricity demand from the time-series workbook
makedemand("Demand", "country1", electricity, snapshot)

# Fixed 1500 MW PV
makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=1500.0,
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

# Smart-charging fleet: 50 000 MWh/year driving; charge only 
makeEV(
    "EV", 50000.0, electricity, snapshot;
    fixed_profile=false,
    smart_charging=true,
    zone="country1",
    charging_eff=0.9,
    self_discharge=0.0,
    min_level_morning=0.0,              # fraction of available battery at 7 am
    max_charging_power_per_ev=0.01,     # MW per vehicle, * fleet size
    battery_capacity_per_ev=0.06,       # MWh per vehicle, * fleet size
    yearly_consumption_per_ev=0.02,     # MWh/year per vehicle (sets fleet size)
)

# Fixed oil backup (continuous UC with startup cost, same plant in both cases)
makedispatchable(
    "Oil", "Oil", electricity, co2, snapshot;
    cap=1200.0,
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
    unit_size=100.0,
    uc=true,
    startup_cost=6_270.0,
    no_load_cost=0.0,
    min_power=0.3,
    min_uptime=2.0,
    min_downtime=2.0,
    startup_duration=1.0,
    shutdown_duration=1.0,
    ramp_up=1.0,
    ramp_down=1.0,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

Annual driving is the fleet's 50 000 MWh target. Charge totals the same, so
nothing is sold to the node. Oil still covers residual demand:

```jldoctest electric_vehicles_smart
julia> driving = balance(result, "EV country1", :output, energy; collapse=true, aggregate=true)
50000.00000000169

julia> charge = balance(result, "EV country1", :input, energy; collapse=true, aggregate=true)
55555.555555555664

julia> balance(result, "Oil country1", :output, energy; collapse=true, aggregate=true)
4.703344672335719e6
```

Over two days charging lines up with lower duals while the fixed driving
profile keeps its shape. Nothing is sold back to the node.

![Smart charging: grid charging, dual price, and driving demand over two days](../assets/electric-vehicles-smart.svg)

## Vehicle-to-grid

The same fleet keeps the same driving need, and may also inject into the
electricity node. Discharge adds a `compensation` cost per MWh, so the
optimiser sells back mainly when the node dual is high enough to cover that
cost. Charging gathers when the dual is low.

```jldoctest electric_vehicles_v2g; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:arguments,
    timeseries_mode=:excel,
)))

# Electricity node (evalprice for dualprice) and CO2 sink
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Hourly electricity demand from the time-series workbook
makedemand("Demand", "country1", electricity, snapshot)

# Fixed 1500 MW PV (same as smart-charging case)
makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=1500.0,
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

# Same fleet and driving need as smart charging, with grid discharge enabled
makeEV(
    "EV", 50000.0, electricity, snapshot;
    fixed_profile=false,
    smart_charging=false,
    vehicle_to_grid=true,
    zone="country1",
    charging_eff=0.9,
    self_discharge=0.0,
    min_level_morning=0.0,              # fraction of available battery at 7 am
    max_charging_power_per_ev=0.01,     # MW per vehicle, * fleet size
    max_dispatch_power_per_ev=0.01,     # MW per vehicle V2G rating, * fleet size
    battery_capacity_per_ev=0.06,       # MWh per vehicle, * fleet size
    yearly_consumption_per_ev=0.02,     # MWh/year per vehicle (sets fleet size)
    compensation=20.0,                  # currency/MWh on grid discharge
)

# Same oil plant as the smart-charging case
makedispatchable(
    "Oil", "Oil", electricity, co2, snapshot;
    cap=1200.0,
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
    unit_size=100.0,
    uc=true,
    startup_cost=6_270.0,
    no_load_cost=0.0,
    min_power=0.3,
    min_uptime=2.0,
    min_downtime=2.0,
    startup_duration=1.0,
    shutdown_duration=1.0,
    ramp_up=1.0,
    ramp_down=1.0,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

Driving stays at 50 000 MWh. With V2G the fleet can also sell power back, so
it cycles like a battery: annual charge rises well above driving, grid
discharge appears, and oil generation reduces:

```jldoctest electric_vehicles_v2g
julia> outputs = balance(result, "EV country1", :output, energy; collapse=true, aggregate=false);

julia> driving = outputs["driving"]
50000.00000000169

julia> discharge = outputs["output"]
411237.08086721296

julia> charge = balance(result, "EV country1", :input, energy; collapse=true, aggregate=true)
512485.64540801453

julia> balance(result, "Oil country1", :output, energy; collapse=true, aggregate=true)
4.490856589540801e6

julia> dualprice(result.nodes["country1"])
8760-element Nosy.Hourly{Float64}:
 68.24
 68.24
 68.24
 68.24
 68.24
 68.24
 68.24
 68.24
 68.24
 68.24
  ⋮
 68.24
 68.24
 68.24
 72.19179192703935
 72.19179192703935
 72.19179192703935
 68.24
 68.24
 68.24
```

`dualprice` returns that hourly node dual.

On the same window as above, charge still sits under low duals, but V2G
discharge appears under high duals when oil is on the margin.

![V2G: grid charging, V2G discharge, dual price, and driving demand over two days](../assets/electric-vehicles-v2g.svg)

### Comparing the two modes

Both runs keep the same country1 demand, 1500 MW of PV, oil backup, and
50 000 MWh annual driving need. Only the EV mode flag flips from
`smart_charging=true` to `vehicle_to_grid=true`. Smart charging exposes
`driving` only. V2G adds a grid `output` (discharge). Driving energy matches in
both cases. Oil generation reduces under V2G because that discharge can cover
residual load.

| | Smart | V2G |
|:---|---:|---:|
| `:output` ports | `driving` only | `driving` + `output` |
| Grid discharge (MWh/year) | 0 | 498812 |
| Oil generation (MWh/year) | 4.703e6 | 4.390e6 |
| Driving energy (MWh/year) | 50000 | 50000 |
