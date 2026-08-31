# Examples

These examples build systems with Posy2's `make...` methods. Nosy still
provides the simulation, snapshot, carriers, and nodes, but the pages do not
assemble Nosy `Component` objects by hand.

Each page is a small working study built around one feature: an
interconnection pattern, a storage technology, a hydrogen pathway. The
remaining assets are kept simple.

| Example | Content |
|:--------|:--------|
| [One Country](examples/one-country.md) | Building and solving a complete single-node study |
| [Dispatchable Generation](examples/dispatchable-generation.md) | Choosing PV and gas capacities, then meeting the residual demand |
| [Dispatch Optimization](examples/dispatch-optimization.md) | Comparing merit-order dispatch with ramp-limited operation of a fixed CCGT fleet |
| [CO2 Pricing](examples/co2-pricing.md) | How a carbon price reorders emitting and non-emitting technologies |
| [Nuclear](examples/nuclear.md) | How refuelling schedule flexibility reduces backup capacity |
| [Battery Storage](examples/battery-storage.md) | Shifting daytime PV generation to later hours |
| [Pumped Storage](examples/pumped-storage-hydro.md) | Using grid electricity to store energy and generate later |
| [Hydro Reservoir](examples/hydro-reservoir.md) | Timing generation by storing variable natural intake |
| [Demand Response](examples/demand-response.md) | Demand-side flexibility that shaves a demand peak |
| [Electric Vehicles](examples/electric-vehicles.md) | Comparing smart charging with vehicle-to-grid operation |
| [Hydrogen Production](examples/hydrogen-production.md) | Producing hydrogen from PV and shifting supply with storage |
| [Two Countries](examples/two-countries.md) | Comparing trade and local generation with and without a transmission limit |
| [Price Interconnection](examples/price-interconnection.md) | Choosing between domestic generation and priced imports |
| [DC OPF](examples/dc-opf.md) | How KVL changes flows across meshed AC lines, and how controllable HVDC differs |
| [Stochastic Programming](examples/stochastic.md) | Sharing investment capacities across two snapshots while operation adapts to each future |
| [Infeasibility](examples/infeasibility.md) | Using `conflicts` to locate incompatible constraints in an infeasible model |

## Data sources

The examples cover all four combinations of `tech_mode` and
`timeseries_mode`. In `:excel` mode, missing values are read from the
technology or time-series workbook, and any keyword you pass on a `make...`
builder overrides that workbook value. In `:arguments` mode there is no
workbook fallback: builders use documented neutral defaults where available
and require the remaining active values explicitly.
The table shows which combination each example uses.

| Example | `tech_mode` | `timeseries_mode` |
|:--------|:------------|:------------------|
| [One Country](examples/one-country.md) | `:excel` | `:excel` |
| [Dispatchable Generation](examples/dispatchable-generation.md) | `:arguments` | `:excel` |
| [Dispatch Optimization](examples/dispatch-optimization.md) | `:arguments` | `:arguments` |
| [CO2 Pricing](examples/co2-pricing.md) | `:arguments` | `:excel` |
| [Nuclear](examples/nuclear.md) | `:excel` | `:excel` |
| [Battery Storage](examples/battery-storage.md) | `:arguments` | `:excel` |
| [Pumped Storage](examples/pumped-storage-hydro.md) | `:arguments` | `:excel` |
| [Hydro Reservoir](examples/hydro-reservoir.md) | `:excel` | `:excel` |
| [Demand Response](examples/demand-response.md) | `:arguments` | `:arguments` |
| [Electric Vehicles](examples/electric-vehicles.md) | `:arguments` | `:excel` |
| [Hydrogen Production](examples/hydrogen-production.md) | `:excel` | `:excel` |
| [Two Countries](examples/two-countries.md) | `:arguments` | `:excel` |
| [Price Interconnection](examples/price-interconnection.md) | `:arguments` | `:excel` |
| [DC OPF](examples/dc-opf.md) | `:excel` | `:arguments` |
| [Negative Locational Prices](examples/negative-prices.md) | `:arguments` | `:arguments` |
| [Stochastic Programming](examples/stochastic.md) | `:arguments` | `:arguments` |
| [Infeasibility](examples/infeasibility.md) | `:arguments` | `:arguments` |

## Exporting Example Results

Every solved example returns a numeric result from `extract(snapshot)`.
[`printsnapshot`](@ref) turns that result into Posy2's standard workbook report:

```julia
printsnapshot(result, "scenario.xlsx")
```

The file is written to `results/scenario.xlsx` and contains annual values for
the complete system and the modelled system boundary, detailed time series,
and price-duration curves. If a file with the same name already exists,
Posy2 moves it to `results/old/` before writing the new report. Call
`printsnapshot` with the extracted result, not the unsolved symbolic snapshot.

Posy2 follows Nosy's unit-agnostic convention: values only need to be
self-consistent. Here, power and capacity are MW, energy is MWh, overnight
investment is currency/kW, fixed operation and maintenance is currency/kW/year,
and variable costs are currency/MWh. The numerical assumptions are deliberately
simple teaching values, not reference projections.
