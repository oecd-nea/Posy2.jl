# Posy2.jl

[![CI](https://github.com/oecd-nea/Posy2.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/oecd-nea/Posy2.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/oecd-nea/Posy2.jl/graph/badge.svg)](https://codecov.io/gh/oecd-nea/Posy2.jl)

Posy2 is a country- and regional-level power system capacity expansion and
dispatch model developed at the OECD Nuclear Energy Agency (OECD-NEA). Built on
[Nosy.jl](https://github.com/oecd-nea/Nosy.jl), it provides a Julia workflow
to assemble power and multi-vector energy system studies, solving
LP and MILP formulations through JuMP-compatible optimisers, and analysing the
resulting costs, capacities, dispatch, storage, prices, and interconnection
flows.

Posy2 is used at the OECD-NEA for country-specific system cost studies,
including: [A Least-cost Capacity Mix to Satisfy Growing Electricity Demand without Carbon Emissions in Sweden](https://www.oecd-nea.org/jcms/pl_116142/a-least-cost-capacity-mix-to-satisfy-growing-electricity-demand-without-carbon-emissions-in-sweden)

## Documentation

The [Posy2 manual](https://oecd-nea.github.io/Posy2.jl/dev/) covers setup, input, component
builders, optimisation, querying, export, performance, and complete examples.
Posy2 builds on the modelling concepts in the
[Nosy user guide](https://oecd-nea.github.io/Nosy.jl/dev/).

API documentation
is also available from the Julia REPL; for example, enter `?makedispatchable`.

## Requirements

Posy2 supports Julia 1.11 and 1.12.
Posy2 also requires an LP or MILP solver compatible with
[JuMP](https://jump.dev/JuMP.jl/stable/). The example below uses
[HiGHS](https://highs.dev/), an open-source solver. Other
[JuMP-compatible solvers](https://jump.dev/JuMP.jl/stable/installation/#Supported-solvers)
can be used when creating the Nosy `Sim`.

## Installation

Posy2 is not yet in the Julia General registry, so install it from its
repository. Nosy is added explicitly: a Posy2 study calls it directly, so it
has to be a dependency of your project and not only of Posy2.

```julia
using Pkg
Pkg.add(url="https://github.com/oecd-nea/Posy2.jl")
Pkg.add(["Nosy", "HiGHS"])  # HiGHS, or another JuMP-compatible solver
```

Check the installation with:

```julia
using Posy2, Nosy, HiGHS
```

## Core Ideas

Posy2 adds a power system modelling layer on top of Nosy:

- High-level constructors(`make*`) assemble and connect common technologies, including
  demand, dispatchable and intermittent generation, nuclear power, hydro,
  batteries, demand response, electrolysers, hydrogen storage, and
  interconnections.
- Technology assumptions and hourly profiles can be read from input data,
  while keyword arguments allow individual values to be overridden.
- Investment and decommissioning costs are annualised before being attached 
  as Nosy fixed costs.
- Solved snapshots can be inspected in Julia or exported to a workbook
  with `printsnapshot`.

Carriers, nodes, behaviours, optimisation, and generic metrics remain provided by Nosy.

## Basic Example

The following model has a sinusoidal electricity demand centred on 100 MW and
one dispatchable plant with optimisable capacity.

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

## Underlying Toolkit: Nosy

Nosy is the composable, component-based energy system modelling toolkit beneath
Posy2. Where Nosy exposes model archetypes and behaviours directly, Posy2 adds
workbook-backed data handling, standard technology constructors, multi-zone
power flow, and energy system reporting.

## Authors

- Guillaume KRIVTCHIK, OECD Nuclear Energy Agency (main author)
- Yuri BAE, KENTECH

## License

This project is licensed under the [MIT License](LICENSE.md).
