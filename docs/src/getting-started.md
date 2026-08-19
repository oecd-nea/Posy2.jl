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

## Installation

Posy2 is not yet in the Julia General registry, so install it from its
repository. Nosy is added explicitly: a study calls Nosy directly for `Sim`,
carriers, nodes, and the query functions, so it has to be a dependency of your
project and not only of Posy2. Nosy itself is registered, so it is added by
name.

```julia
using Pkg
Pkg.add(url="https://github.com/oecd-nea/Posy2.jl")
Pkg.add(["Nosy", "HiGHS"])  # HiGHS, or another JuMP-compatible solver
```

Check the installation with:

```julia
using Posy2, Nosy, HiGHS
```

## Minimal Workflow

The following model has a flat 100 MW electricity demand and one dispatchable
plant with optimisable capacity.

```julia
using Posy2
using Nosy
using HiGHS

# Create the Nosy simulation and silence solver output.
s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())

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

# Add a demand with sin shape centered around 100 MW
makedemand("Load", "grid", grid, snapshot; profile=100.0 .+ 30 * sin.(h*2pi/24 for h in 1:8760))

# Add a dispatchable generator with optimisable capacity.
makedispatchable(
    "CCGT",
    "CCGT",
    grid,
    atmosphere,
    snapshot;
    overnight_cost=1_000.0,      # overnight investment cost (USD/kW)
    lifetime=30,                 # economic lifetime (years)
    construction_profile=1.0,    # one-year construction
    fuel_cost=70.0,              # fuel cost per MWh (USD/MWh)
    co2_emission=350.0,          # CO2 emission (kg/MWh)
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
