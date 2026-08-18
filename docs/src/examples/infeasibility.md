# Infeasibility

This example makes the gas plant capacity upper bound too low. The model is infeasible
because demand cannot be covered during hours without PV output.

```jldoctest infeasibility; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
)))

# Electricity node and CO2 sink
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Synthetic load profile
hours = 1:8760
day_angle = 2pi .* ((hours .- 1) .% 24) ./ 24
season_angle = 2pi .* (hours .- 1) ./ 8760
load_profile = 3000 .+ 1500 .* sin.(day_angle .- pi / 2) .+
    120 .* sin.(season_angle .- pi / 2)

# Synthetic PV capacity-factor profile
cf_pv = [
    x < 1e-6 ? 0.0 : x for x in [
        max(0, cos((h % 24 - 12) / 12 * pi) * (0.6 + 0.4 * sin(2pi * (h / 24) / 365)))
        for h in 1:8760
    ]
]

makedemand("Demand", "country1", electricity, snapshot; profile=load_profile)

makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=10000.0,
    profile=cf_pv,
)

# Gas capacity is optimised, but maximum capacity is too low
makedispatchable(
    "Gas", "CCGT", electricity, co2, snapshot;
    maxcap=3500.0,
    fuel_cost=50.0,
)

# Minimise total operating cost
optimize!(snapshot, cost(snapshot))
snapshot

# output

Snapshot with 3 component(s) and 1 node(s)

```

The model warns that the problem was not solved.

```jldoctest infeasibility
julia> result = extract(snapshot)
┌ Warning: System is not optimised. Termination status: INFEASIBLE. Returning the problem instead of the result.
└ @ Nosy ~/.julia/packages/Nosy/YY1j3/src/opti/extract.jl:24
Snapshot with 3 component(s) and 1 node(s)
```

Some solvers can compute an irreducible infeasible subsystem (IIS) for the
problem. When available, the IIS identifies a set of conflicting constraints.
An IIS is not unique: a problem may have several, and repairing one IIS does not
necessarily make the problem feasible.

```jldoctest infeasibility
julia> conflicts(result)
2-element Vector{JuMP.ConstraintRef}:
 Gas country1_energy_out[4386] ≥ 3508.227796
 Gas country1_energy_out[4386] - Gas country1_output_energy_cap_ ≤ 0
```

The result is easily interpretable: in this hour the gas plant must supply above
3508 MW, but its optimised capacity is constrained by the `maxcap=3500` upper
bound. The actual minimum feasible gas capacity is about 3508.23 MW:

```jldoctest infeasibility
julia> maximum(iszero(cf_pv[i]) ? load_profile[i] : 0.0 for i in eachindex(load_profile))
3508.2277959647663
```

Raising the gas capacity upper bound to 3509 MW restores feasibility.

```jldoctest infeasibility_fixed; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
)))

# Electricity node and CO2 sink
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Same synthetic profiles as above
hours = 1:8760
day_angle = 2pi .* ((hours .- 1) .% 24) ./ 24
season_angle = 2pi .* (hours .- 1) ./ 8760
load_profile = 3000 .+ 1500 .* sin.(day_angle .- pi / 2) .+
    120 .* sin.(season_angle .- pi / 2)

cf_pv = [
    x < 1e-6 ? 0.0 : x for x in [
        max(0, cos((h % 24 - 12) / 12 * pi) * (0.6 + 0.4 * sin(2pi * (h / 24) / 365)))
        for h in 1:8760
    ]
]

makedemand("Demand", "country1", electricity, snapshot; profile=load_profile)

makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=10000.0,
    profile=cf_pv,
)

# Higher gas capacity upper bound
makedispatchable(
    "Gas", "CCGT", electricity, co2, snapshot;
    maxcap=3509.0,
    fuel_cost=50.0,
)

# Minimise total operating cost
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 1 node(s)

```
