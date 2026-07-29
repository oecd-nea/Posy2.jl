# Introduction

POSY2.jl is a country- and regional-level power system capacity expansion and
dispatch model developed at the
[OECD Nuclear Energy Agency](https://oecd-nea.org/). It builds on
[Nosy.jl](https://github.com/oecd-nea/Nosy.jl) and provides a higher-level Julia
workflow for constructing power and multi-vector energy system studies from
standard technology assumptions and hourly time series.

POSY2 components remain ordinary Nosy components. The component builders
assemble model archetypes, behaviours, costs, capacities, emissions, storage
relations, and connections, while Nosy supplies the shared simulation,
optimisation, and querying machinery. This makes it possible to use the
convenient POSY2 workflow and still extend a study directly with Nosy and JuMP.

## Key Capabilities

- Build demand, generation, storage, conversion, and interconnection
  components with consistent naming and tags.
- Read technology assumptions and hourly profiles from Excel workbooks, or
  override individual technology parameters from Julia.
- Represent fixed or optimisable capacity, unit commitment, ramping, storage,
  demand response, electric vehicles, hydrogen, and CO2.
- Connect several zones with price-based or node-based interconnections.
- Add an optional cycle-based DC power flow formulation for AC networks.
- Solve LP and MILP formulations with JuMP-compatible optimisers.
- Inspect costs, capacities, balances, prices, and interconnection flows, then
  export standard post-processing tables to an Excel workbook.

Start with [Getting Started](getting-started.md) for a workbook-free model.
[Modelling Concepts](concepts.md) explains how POSY2 maps study assumptions to
Nosy objects, and [Examples](examples.md) develops complete systems one feature
at a time.
