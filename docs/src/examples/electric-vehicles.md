# Electric Vehicles

[`makeEV`](@ref) can run as a fixed charging shape, smart charging, or
vehicle-to-grid. Exactly one of `fixed_profile`, `smart_charging`, and
`vehicle_to_grid` must be `true`. This page uses smart charging: the fleet
charges from the grid when it is cheap, stores energy, and spends it later on
driving. It does **not** discharge back to the node—that is the V2G mode.

Early solar from [`makeintermittentsource`](@ref), flat ordinary demand, and an
oil plant make the timing readable. Workbook-scale assumptions (about 10 kW
charge power, 60 kWh battery, 90% efficiency) stay as teaching values. The
`yearly` argument is the fleet's annual driving energy; solar and driving
profiles repeat the same daily pattern over the year.

With `smart_charging=true`, the optimiser chooses the charge hours.
`driving_profile` still forces evening consumption through the EV `output`
port (the unconnected driving draw documented for flexible modes). Stored
`level` links the two: charge raises it, driving lowers it.

```jldoctest electric_vehicles_smart; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
)))

electricity = Node("COUNTRY", EnergyCarrier("electricity COUNTRY", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "COUNTRY", electricity, snapshot; coeff=0.0, yearlyconstant=50.0 * 8760)

makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=100.0,
    profile=repeat(vcat(ones(6), zeros(18)), 365),
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

makeEV(
    "EV", 730.0, electricity, snapshot;
    fixed_profile=false,
    smart_charging=true,
    charging_availability=ones(8760),
    driving_profile=repeat(vcat(zeros(12), ones(12)), 365),
    charging_eff=0.9,
    self_discharge=0.0,
    min_level_morning=0.0,
    max_charging_power_per_ev=0.01,
    max_dispatch_power_per_ev=0.0,
    battery_capacity_per_ev=0.06,
    yearly_consumption_per_ev=0.02,
)

makedispatchable(
    "Oil", "Oil", electricity, co2, snapshot;
    cap=80.0,
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

Grid charging (`:input`) lands in the early solar window. A typical day shows
a single charge pulse while free PV is available:

```jldoctest electric_vehicles_smart
julia> charge = balance(result, "EV COUNTRY", :input, energy; collapse=false, aggregate=true);

julia> charge[1:24]
24-element Vector{Float64}:
 0.0
 2.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0

julia> findfirst(!iszero, charge), findlast(!iszero, charge)
(2, 8740)
```

In smart-charging mode the EV `:output` is the fixed **driving** draw, not a
V2G injection into the electricity node. It follows the evening half of
`driving_profile` and sums to the annual `yearly` total:

```jldoctest electric_vehicles_smart
julia> driving = balance(result, "EV COUNTRY", :output, energy; collapse=false, aggregate=true);

julia> driving[1:24]
24-element Vector{Float64}:
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.0
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666
 0.16666666666666666

julia> sum(driving)
730.0000000000002
```

The battery `level` ties the two together: it rises when the fleet charges,
holds through the idle hours, then falls once driving starts. Oil still covers
ordinary demand on the node; the cars are not exporting power.

```jldoctest electric_vehicles_smart
julia> level = balance(result, "EV COUNTRY", :level, energy; collapse=false, aggregate=true);

julia> level[1:24]
24-element Vector{Float64}:
 0.0
 0.0
 2.0
 2.0
 2.0
 2.0
 2.0
 2.0
 2.0
 2.0
 2.0
 2.0
 2.0
 1.8333333333333335
 1.6666666666666667
 1.5
 1.3333333333333333
 1.1666666666666665
 0.9999999999999999
 0.8333333333333333
 0.6666666666666666
 0.5
 0.3333333333333333
 0.16666666666666666
```

Fixed-profile and V2G modes reuse the same [`makeEV`](@ref) builder with
different flags. V2G adds a true grid `:output` (dispatch) beside driving;
smart charging keeps only the driving side of that story.
