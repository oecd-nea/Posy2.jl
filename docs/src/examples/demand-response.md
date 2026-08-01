# Demand Response

[`makedemandresponse`](@ref) is a costed, capacity-limited flexibility on the
demand side. Its connected flow is negative consumption. 
It runs only when that is cheaper than the alternatives on the node.

Daytime PV from [`makeintermittentsource`](@ref) covers the flat 80 MW load
while the sun is up. At night the residual is shared between demand response
(30 MW at 40 currency/MWh) and oil (68.24 currency/MWh fuel). DR is unused in
the day because free solar already meets demand. The PV profile repeats the
same 12-on / 12-off day over the year.

```jldoctest demand_response; output = false
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

makedemand("Demand", "COUNTRY", electricity, snapshot; coeff=0.0, yearlyconstant=80.0 * 8760)

makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=100.0,
    profile=repeat(vcat(ones(12), zeros(12)), 365),
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
    cap=100.0,
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

makedemandresponse("DR", electricity, 30.0, 40.0, snapshot)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

A typical day shows the pattern: DR stays at zero through the PV window, then
saturates its 30 MW rating every night hour. Oil fills the remaining 50 MW of
the 80 MW load:

```jldoctest demand_response
julia> dr = balance(result, "DR COUNTRY", :output, energy; collapse=false, aggregate=true);

julia> oil = balance(result, "Oil COUNTRY", :output, energy; collapse=false, aggregate=true);

julia> dr[1:24]
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
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0
 30.0

julia> oil[1:24]
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
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
```

The merit order is the whole point: DR is cheaper than oil, so it is used up
to its capacity before the oil plant runs. Raising the DR cost above the oil
fuel cost would reverse that night split.
