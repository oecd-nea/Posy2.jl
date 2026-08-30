# Demand Response

This example shows how demand response can shave a demand peak and avoid more
expensive generation. A typical daily load, repeated all year, sits with fixed
PV, gas capacity chosen in the cost minimisation, and 30 MW of demand response
at 40 currency/MWh.

[`makedemandresponse`](@ref) is a costed, capacity-limited flexibility on the
demand side. Its connected flow is negative consumption. It runs only when 
that is cheaper than the alternatives on the node.

```jldoctest demand_response; output = false
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

# Typical daily demand (daytime bump, evening peak)
day = [58.0, 55.0, 53.0, 52.0, 54.0, 60.0, 72.0, 82.0, 88.0, 86.0, 84.0, 82.0, 80.0, 78.0, 77.0, 80.0, 88.0, 96.0, 100.0, 97.0, 90.0, 78.0, 68.0, 62.0]
makedemand("Demand", "country1", electricity, snapshot; profile=repeat(day, 365))

# Fixed 100 MW PV
pvday = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.125, 0.25, 0.5, 0.75, 1.0, 1.0, 1.0, 1.0, 0.75, 0.5, 0.25, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
makeintermittentsource(
    "Solar", electricity, co2, snapshot; tech_column="PV",
    cap=100.0,
    profile=repeat(pvday, 365),
)

# Gas: capacity chosen in the cost minimisation
makedispatchable(
    "Gas", electricity, co2, snapshot; tech_column="Gas",
    maxcap=150.0,
    overnight_cost=800.0,
    lifetime=30,
    construction_profile=1.0,
    fuel_cost=20.0,
)

# Demand response: 30 MW at 40 currency/MWh
makedemandresponse("DR", electricity, 30.0, 40.0, snapshot)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

PV covers much of the daytime load, but the 100 MW evening peak still needs
gas capacity. Demand response at 40 currency/MWh is worth using on those
peak hours, so the optimiser builds 70 MW of gas instead of matching the full
peak:

```jldoctest demand_response
julia> table(result, capacity)
1×4 DataFrame
 Row │ DR country1  Demand country1  Gas country1  Solar country1
     │ Float64      Float64          Float64       Float64
─────┼────────────────────────────────────────────────────────────
   1 │        30.0              0.0          70.0           100.0
```

Demand response stays off for most of the day and fills only the evening peak.
Gas covers the night and daytime residual, then hits its installed capacity 
on the evening peak:

```jldoctest demand_response
julia> balance(result, "DR country1", :output, energy; collapse=false, aggregate=true)
8760-element Nosy.Hourly{Float64}:
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
  ⋮
  0.0
  0.0
 13.5
 30.0
 27.0
 20.0
  8.0
  0.0
  0.0

julia> balance(result, "Gas country1", :output, energy; collapse=false, aggregate=true)
8760-element Nosy.Hourly{Float64}:
 58.0
 55.0
 53.0
 52.0
 54.0
 60.0
 59.5
 57.0
 38.0
 11.0
  ⋮
 30.0
 63.0
 70.0
 70.0
 70.0
 70.0
 70.0
 68.0
 62.0
```

Without demand response the same peak needs 100 MW of gas:

```jldoctest demand_response_noshave; output = false
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

# Same daily demand as above
day = [58.0, 55.0, 53.0, 52.0, 54.0, 60.0, 72.0, 82.0, 88.0, 86.0, 84.0, 82.0, 80.0, 78.0, 77.0, 80.0, 88.0, 96.0, 100.0, 97.0, 90.0, 78.0, 68.0, 62.0]
makedemand("Demand", "country1", electricity, snapshot; profile=repeat(day, 365))

# Same fixed PV
pvday = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.125, 0.25, 0.5, 0.75, 1.0, 1.0, 1.0, 1.0, 0.75, 0.5, 0.25, 0.125, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
makeintermittentsource(
    "Solar", electricity, co2, snapshot; tech_column="PV",
    cap=100.0,
    profile=repeat(pvday, 365),
)

# Same gas plant, no demand response
makedispatchable(
    "Gas", electricity, co2, snapshot; tech_column="Gas",
    maxcap=150.0,
    overnight_cost=800.0,
    lifetime=30,
    construction_profile=1.0,
    fuel_cost=20.0,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 1 node(s)

```

```jldoctest demand_response_noshave
julia> table(result, capacity)
1×3 DataFrame
 Row │ Demand country1  Gas country1  Solar country1
     │ Float64          Float64       Float64
─────┼───────────────────────────────────────────────
   1 │             0.0         100.0           100.0

julia> balance(result, "Gas country1", :output, energy; collapse=false, aggregate=true)
8760-element Nosy.Hourly{Float64}:
  58.0
  55.0
  53.0
  52.0
  54.0
  60.0
  59.5
  57.0
  38.0
  11.0
   ⋮
  30.0
  63.0
  83.5
 100.0
  97.0
  90.0
  78.0
  68.0
  62.0
```

The 30 MW of demand response is not free energy: it is a costed option in the
same minimisation as generation. At 40 currency/MWh it is worth using on the
peak hours, so less gas is built. Raising that cost can make building the
extra gas capacity the cheaper choice again.
