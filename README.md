# POSY2.jl

POSY2 is a country- and regional-level power system capacity expansion and
dispatch model developed at the OECD Nuclear Energy Agency (OECD-NEA). Built on
[Nosy.jl](https://github.com/oecd-nea/Nosy.jl), it provides a Julia workflow
to assemble power and multi-vector energy system studies, solving
LP and MILP formulations through JuMP-compatible optimisers, and analysing the
resulting costs, capacities, dispatch, storage, prices, and interconnection
flows.

POSY2 is used at the OECD-NEA for country-specific system cost studies,
including: [A Least-cost Capacity Mix to Satisfy Growing Electricity Demand without Carbon Emissions in Sweden](https://www.oecd-nea.org/jcms/pl_116142/a-least-cost-capacity-mix-to-satisfy-growing-electricity-demand-without-carbon-emissions-in-sweden)

## Documentation

The [POSY2 manual](docs/src/index.md) covers setup, input workbooks, component
builders, optimisation, querying, export, performance, and complete examples.
POSY2 builds on the modelling concepts in the
[Nosy user guide](https://oecd-nea.github.io/Nosy.jl/dev/).

API documentation
is also available from the Julia REPL; for example, enter `?makedispatchable`.

## Requirements

POSY2 currently uses Nosy's
[`POSY2_refactoring`](https://github.com/oecd-nea/Nosy.jl/tree/POSY2_refactoring)
branch, which is planned for Nosy v0.3.0. It supports Julia 1.11 and 1.12.
POSY2 also requires an LP or MILP solver compatible with
[JuMP](https://jump.dev/JuMP.jl/stable/). The example below uses
[HiGHS](https://highs.dev/), an open-source solver. Other
[JuMP-compatible solvers](https://jump.dev/JuMP.jl/stable/installation/#Supported-solvers)
can be used when creating the Nosy `Sim`.

Scenario data can be supplied through two Excel workbooks, directly through
builder arguments, or with a mixture of both. Independent `tech_mode` and
`timeseries_mode` switches in `POSY2Options` control the fallback behavior.
POSY2 includes neutral, illustrative workbooks in [`data/`](data/) for the
manual and examples; they are not calibrated scenario projections.

## Core Ideas

POSY2 adds a power system modelling layer on top of Nosy:

- `POSY2Options` configures technology data, time-series data, the discount
  rate, the CO2 price, and optional DC power flow. Call `applydcopf!` before
  optimisation to add KVL constraints when DC power flow is enabled.
- High-level constructors(`make*`) assemble and connect common technologies, including
  demand, dispatchable and intermittent generation, nuclear power, hydro,
  batteries, demand response, electrolysers, hydrogen storage, and
  interconnections.
- Technology assumptions and hourly profiles can be read directly from Excel,
  while keyword arguments allow individual values to be overridden.
- Investment and decommissioning costs are annualised before being attached 
  as Nosy fixed costs.
- Solved snapshots can be inspected in Julia or exported to an Excel workbook
  with `printsnapshot`.

Carriers, nodes, behaviours, optimisation, and generic metrics remain provided by Nosy.

## Basic Example

The following self-contained example creates a flat 100 MW demand and optimises
the capacity and dispatch of one generator. All technology parameters are
provided explicitly, so no input workbooks are read.

```julia
using POSY2
using Nosy
using HiGHS

# Create a simulation with the default hourly time mesh.
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
snapshot = Snapshot(
    sim,
    Dict(:posy => POSY2Options(
        tech_mode=:arguments,
        timeseries_mode=:arguments,
        discountrate=0.05,
        co2_price=0.0,
    )),
)

# Create electricity and CO2 nodes.
electricity = Node("grid", EnergyCarrier("electricity", sim); rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim); rule=:curtailed, tags=[:co2])

# Add a flat 100 MW demand: 100 MW × 8760 hours.
makedemand("Load", "unused", electricity, snapshot; coeff=0.0, yearlyconstant=876_000.0)

# Add a dispatchable generator with optimisable capacity.
makedispatchable(
    "Plant",
    "unused",
    electricity,
    co2,
    snapshot;
    maxcap=200.0,
    overnight_cost=1_000.0,
    om_fixed_cost=10.0,
    decommissioning=0.1,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=2.0,
    fuel_cost=50.0,
    co2_emission=0.0,
    unit_size=0.0,
)

# Minimise total system cost and extract the solution.
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# Inspect results.
cost(result)
capacity(result, "Plant grid") # 100.0 MW
balance(result, "Plant grid", :output, energy; collapse=true, aggregate=true) # 876000.0 MWh
```

## Underlying Toolkit: Nosy

Nosy is the composable, component-based energy system modelling toolkit beneath
POSY2. Where Nosy exposes model archetypes and behaviours directly, POSY2 adds
workbook-backed data handling, standard technology constructors, multi-zone
power flow, and energy system reporting for analysts and scenario builders.

## Authors

- Guillaume KRIVTCHIK, OECD Nuclear Energy Agency
- Yuri BAE, KENTECH

## License

This project is licensed under the [MIT License](LICENSE.md).
