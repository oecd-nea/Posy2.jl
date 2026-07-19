# Pumped-storage Hydro

Pumped storage has both grid-charging and turbine capacities but no natural
inflow. The following 24-hour model uses [`makedispatchable`](@ref) with an
availability profile to represent a source available only during the first 12
hours. [`makehydroreservoir`](@ref) pumps during those hours and generates
during the other 12.

```jldoctest pumped_storage; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1//1, 24)))
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
)))

electricity = Node(
    "COUNTRY",
    EnergyCarrier("electricity COUNTRY", sim),
    rule=:curtailed,
    tags=[:electricity],
)
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand(
    "Demand", "unused", electricity, snapshot;
    coeff=0.0,
    yearlyconstant=50.0 * 8760,
)

makedispatchable(
    "Available source", "unused", electricity, co2, snapshot;
    cap=125.0,
    capacitymultiplier=vcat(ones(12), zeros(12)),
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=1.0,
    co2_emission=0.0,
    unit_size=0.0,
)

# Expensive backup keeps the model feasible and makes storage valuable.
makedispatchable(
    "Backup", "unused", electricity, co2, snapshot;
    cap=50.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=100.0,
    co2_emission=0.0,
    unit_size=0.0,
)

makehydroreservoir(
    "Pumped hydro",
    "unused",
    "COUNTRY",
    electricity,
    50.0,  # turbine capacity
    75.0,  # pumping capacity
    750.0, # reservoir energy capacity
    0.0,   # no natural inflow
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
julia> balance(result, "Pumped hydro COUNTRY", :input, energy; collapse=true, aggregate=true)
750.0

julia> balance(result, "Pumped hydro COUNTRY", :output, energy; collapse=true, aggregate=true)
600.0

julia> balance(result, "Backup COUNTRY", :output, energy; collapse=true, aggregate=true)
0.0
```

The plant consumes 750 MWh and returns 600 MWh at 80% input efficiency. These
are deliberately separate from the reservoir-hydro inputs: pumped storage has
positive `cap_charging` and `inflow=0`, whereas a natural-inflow reservoir
normally has `cap_charging=0` and a positive or workbook-backed inflow.
