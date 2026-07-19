# Examples

These examples build components exclusively through POSY2's `make...`
methods. Nosy still supplies the simulation, snapshot, carriers, and nodes on
which POSY2 operates, but the examples do not assemble Nosy `Component`
objects by hand.

The examples progress from a single copperplate country to interconnected
countries and then add DC optimal power flow. Two hydro examples demonstrate
the distinct natural-inflow reservoir and pumped-storage configurations of
[`makehydroreservoir`](@ref).

Together, the examples exercise all four input-mode combinations:

| Example | `tech_mode` | `timeseries_mode` | Purpose |
|:--------|:------------|:------------------|:--------|
| Copperplate Country | `:excel` | `:excel` | Paired demand, wind profile, Onwind, and CCGT data |
| Hydro Reservoir | `:excel` | `:excel` | Paired reservoir inflow, Hydro res, and CCGT data |
| Copperplate Country with Hydrogen | `:excel` | `:arguments` | Workbook PEM/CCGT assumptions with explicit flat demands |
| Copperplate Country with a Priced Neighbour | `:arguments` | `:excel` | Workbook prices and directional availability without technology lookups |
| Short network and pumped-storage examples | `:arguments` | `:arguments` | Fully self-contained teaching models |

- [Copperplate Country](examples/copperplate-country.md)
- [Copperplate Country with Hydrogen](examples/copperplate-hydrogen.md)
- [Copperplate Country with a Priced Neighbour](examples/copperplate-price-interconnection.md)
- [Two Copperplate Countries](examples/two-countries.md)
- [Four Copperplate Countries](examples/four-countries.md)
- [Four Countries with DC OPF](examples/four-countries-dcopf.md)
- [Hydro Reservoir](examples/hydro-reservoir.md)
- [Pumped-storage Hydro](examples/pumped-storage-hydro.md)

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
