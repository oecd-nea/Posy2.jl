# Getting Started

Posy2 is a modelling layer on top of Nosy. A normal workflow creates a Nosy
simulation, stores [`Posy2Options`](@ref) in a snapshot, creates the required
carriers and nodes, calls Posy2 component builders, optimises the resulting
Nosy snapshot, and extracts its solution.

## Requirements

Posy2 requires Nosy v0.3.0 and an LP or MILP solver compatible with
[JuMP](https://jump.dev/JuMP.jl/stable/). The examples in this documentation
use [HiGHS](https://highs.dev/) because it is open source and supports the
linear examples used here. Other
[JuMP-compatible solvers](https://jump.dev/JuMP.jl/stable/installation/#Supported-solvers)
can be used the same way. Please note: some solvers require a separate installation and licence.

Use a Julia environment in which Posy2, Nosy, and the selected solver are
already available.

## Minimal Workflow

The following model has a flat 100 MW electricity demand and one dispatchable
plant with optimisable capacity.

```julia
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Create the Nosy simulation and silence solver output.
s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(s))

# Posy2 options are stored under the :posy key of the snapshot.
options = Posy2Options(
    tech_mode=:arguments,       # supply technology parameters directly
    timeseries_mode=:arguments, # supply time series directly
)
snapshot = Snapshot(s, Dict(:posy => options))

# Create the carriers and nodes used by the component builders.
power = EnergyCarrier("electricity", s)
carbon = CO2Carrier("CO2", s)

grid = Node("grid", power; rule=:curtailed, tags=[:electricity])
atmosphere = Node("CO2", carbon; rule=:curtailed, tags=[:co2])

# Add a demand with sin shape centered arouund 100 MW
makedemand("Load", "grid", grid, snapshot; profile=100.0 .+ 30 * sin.(h*2pi/24 for h in 1:8760))

# Add a dispatchable generator with optimisable capacity.
makedispatchable(
    "CCGT",
    "CCGT",
    grid,
    atmosphere,
    snapshot;
    maxcap=200.0,                   # upper bound on capacity (MW)
    overnight_cost=1_000.0,         # overnight investment cost (USD/kW)
    om_fixed_cost=10.0,             # fixed O&M (USD/kW/y)
    decommissioning=0.05,           # fraction of overnight cost, paid at end of lifetime
    lifetime=30,                    # economic lifetime (years)
    construction_profile=1.0,       # one-year construction spend
    decommissioning_profile=1.0,    # one-year decommissioning spend
    connection_cost=0.1,            # fraction of investment cost, paid at commissioning
    om_var_cost=2.0,                # variable O&M per MWh (USD/MWh)
    fuel_cost=70.0,                 # fuel cost per MWh (USD/MWh)
    co2_emission=350.,              # CO2 emission (kg/MWh)
    unit_size=100.0,                # unit size (MW)
)

# Minimise total system cost and extract numeric results.
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)
```

The component name combines the builder's name prefix and the node name.
The solved capacity and annual generation are therefore:

```julia
capacity(result, "CCGT grid") # in MW
# 130.0

balance(result, "CCGT grid", :output, energy; collapse=true, aggregate=true) # in MWh/y
# 876000.0
```

The original `snapshot` contains JuMP variables and expressions. The extracted
`result` has the same structure, but is populated with optimal values when the
optimisation succeeds.

## Inspecting Results

Nosy's normal metrics work directly on Posy2 snapshots:

```julia
# Total annual system cost in USD/y
cost(result)

# Cost breakdown by component and cost tag.
costs(result)

# Component capacities.
table(result, capacity)

# Hourly plant output.
balance(result, "CCGT grid", :output, energy; collapse=false, aggregate=true)
```