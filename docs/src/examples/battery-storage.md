# Battery Storage

Flat demand with workbook PV leaves evenings short of solar.
[`makebatterystorage`](@ref) shifts surplus daytime energy forward on the same
electricity node. An oil plant covers hours that the battery cannot reach.

The PV profile is read from `time_series.xlsx` (`PV_country1` in
`profiles_2019`) through [`makeintermittentsource`](@ref). Storage and oil
costs stay as argument-mode teaching values (`tech_mode=:arguments`,
`timeseries_mode=:excel`).

```jldoctest battery_storage; output = false
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
    cap=100.0,
    weatheryear=2019,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=25,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=15.0,
    fuel_cost=0.0,
    co2_emission=0.0,
)

makebatterystorage(
    "Battery", "Battery", electricity, snapshot;
    capin=50.0,
    eff=0.85,
    duration=4.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=10,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
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

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

Expected results:

```jldoctest battery_storage
julia> charge = balance(result, "Battery country1", :input, energy; collapse=false, aggregate=true);

julia> discharge = balance(result, "Battery country1", :output, energy; collapse=false, aggregate=true);

julia> balance(result, "Battery country1", :input, energy; collapse=true, aggregate=true)
12021.6263

julia> balance(result, "Battery country1", :output, energy; collapse=true, aggregate=true)
10218.382355000003

julia> round(balance(result, "Battery country1", :output, energy; collapse=true, aggregate=true) /
            balance(result, "Battery country1", :input, energy; collapse=true, aggregate=true); digits=2)
0.85

julia> maximum(charge), maximum(discharge)
(38.3065, 49.984)

julia> balance(result, "Oil country1", :output, energy; collapse=true, aggregate=true)
303143.4761450002
```

Annual charge (`:input`) and discharge (`:output`) recover the stated 85%
round-trip efficiency. Peak charge stays below the 50 MW charger; peak
discharge nearly fills that rating. Oil still supplies most of the year
because the battery only shifts a slice of the solar surplus. The storage
`level` rises while charging and falls while discharging;
`argmax(level)` marks a peak within that daily shift:

```jldoctest battery_storage
julia> level = balance(result, "Battery country1", :level, energy; collapse=false, aggregate=true);

julia> peak = argmax(level)
4073

julia> level[peak-5:peak+5]
11-element Vector{Float64}:
  66.8928325
  99.4533575
 129.719605
 152.7203925
 162.30631
 162.877425
 160.2777575
 137.30159
  92.07839
  67.23169
  67.23169

julia> maximum(level)
162.877425
```

The same hourly loop is in the Excel report. Write it with
[`printsnapshot`](@ref):

```jldoctest battery_storage
julia> printsnapshot(result, "battery-storage.xlsx")
```

That creates `results/battery-storage.xlsx`. In the **Time series** sheet, the
`charging Battery country1`, `discharging Battery country1`, and
`levelBattery country1` columns (GW / GWh) show the same charge–store–discharge
pattern as the `balance` queries above. The figure below is one full day around
the level peak at hour 4073: daytime PV surplus fills the battery, level peaks,
then evening discharge covers the solar drop before oil takes over again.

![Battery charge, discharge, and level over one day from the printsnapshot Time series sheet](../assets/battery-storage.png)

`duration=4.0` sets energy capacity from the charge rating
(`capin * duration`). The example is about that charge–store–discharge loop on
one node, not about sizing a full storage fleet.
