# Examples

These examples build systems with POSY2's `make...` methods. Nosy still
provides the simulation, snapshot, carriers, and nodes, but the pages do not
assemble Nosy `Component` objects by hand.

Each page is a small working study with one idea in focus—an interconnection
pattern, a storage technology, a hydrogen pathway—while other assets stay as
supporting pieces. Result queries follow the story: `capacity` and annual
`balance`/`cost` where totals matter, hourly `balance` where the time pattern
matters. Price Interconnection adds one figure so the price-based switch
between imports and domestic generation is visible.

Together, the examples exercise all four input-mode combinations:

| Example | `tech_mode` | `timeseries_mode` | Purpose |
|:--------|:------------|:------------------|:--------|
| [One Country](examples/one-country.md) | `:excel` | `:excel` | Paired demand, wind profile, Onwind, and CCGT data |
| [Hydro Reservoir](examples/hydro-reservoir.md) | `:excel` | `:excel` | Paired reservoir inflow with Hydro res and CCGT data |
| [Dispatchable Generation](examples/dispatchable-generation.md) / [Hydrogen](examples/hydrogen-production.md) | `:excel` | `:arguments` | Workbook technology assumptions with explicit demands |
| [Price Interconnection](examples/price-interconnection.md), [Battery](examples/battery-storage.md), [Pumped Storage](examples/pumped-storage-hydro.md) | `:arguments` | `:excel` | Workbook series (prices, profiles, or availability) with explicit technology costs |
| [Two Countries](examples/two-countries.md), [DC OPF](examples/dc-opf.md), [EV](examples/electric-vehicles.md), [Demand Response](examples/demand-response.md) | `:arguments` | `:arguments` | Fully self-contained teaching models |

- [One Country](examples/one-country.md)
- [Two Countries](examples/two-countries.md)
- [Price Interconnection](examples/price-interconnection.md)
- [DC OPF](examples/dc-opf.md)
- [Dispatchable Generation](examples/dispatchable-generation.md)
- [Battery Storage](examples/battery-storage.md)
- [Hydro Reservoir](examples/hydro-reservoir.md)
- [Pumped Storage](examples/pumped-storage-hydro.md)
- [Hydrogen Production](examples/hydrogen-production.md)
- [Electric Vehicles](examples/electric-vehicles.md)
- [Demand Response](examples/demand-response.md)

## Exporting Example Results

Every solved example returns a numeric `result` from `extract(snapshot)`.
[`printsnapshot`](@ref) turns that result into POSY2's standard Excel report:

```julia
printsnapshot(result, "scenario.xlsx")
```

The file is written to `results/scenario.xlsx` and contains annual values for
the complete system and the modelled system boundary, detailed time series,
and price-duration curves. If a file with the same name already exists,
POSY2 moves it to `results/old/` before writing the new report. Call
`printsnapshot` with the extracted result, not the unsolved symbolic snapshot.

POSY2 follows Nosy's unit-agnostic convention: values only need to be
self-consistent. Here, power and capacity are MW, energy is MWh, overnight
investment is USD/kW, fixed operation and maintenance is USD/kW/year, and
variable costs are USD/MWh. The numerical assumptions are deliberately simple
teaching values, not reference projections.
