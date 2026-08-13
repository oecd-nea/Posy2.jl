# Introduction

Posy2.jl is a country- and regional-level power system capacity expansion and
dispatch model developed at the
[OECD Nuclear Energy Agency](https://oecd-nea.org/). It builds on
[Nosy.jl](https://github.com/oecd-nea/Nosy.jl) and provides a higher-level Julia
workflow for constructing power and multi-vector energy system studies from
standard technology assumptions and hourly time series.

Posy2 components remain ordinary Nosy components. The component builders
assemble model archetypes, behaviours, costs, capacities, emissions, storage
relations, and connections, while Nosy supplies the shared simulation,
optimisation, and querying machinery. This makes it possible to use the
convenient Posy2 workflow and still extend a study directly with Nosy.

## Key Capabilities

- Assemble demand, generation, storage, conversion, and interconnection
  components with consistent naming and tags on top of Nosy.
- Load technology assumptions and hourly profiles from input data, or set
  them from Julia.
- Run multi-zone capacity expansion and dispatch with price- or node-based
  interconnections and optional DC power flow.
- Cover power-system features such as unit commitment, demand response,
  electric vehicles, hydrogen, and CO2.
- Inspect costs, capacities, balances, and prices, then export standard
  post-processing tables to a workbook.

Start with [Getting Started](getting-started.md) for a simple example.
[Modelling Concepts](concepts.md) explains how Posy2 maps study assumptions to
Nosy objects, and [Examples](examples.md) develops complete systems one feature
at a time.

## Licence
Posy2 is available under the [MIT licence](https://github.com/GKrivtchik/Posy2.jl/blob/main/LICENSE.md).
