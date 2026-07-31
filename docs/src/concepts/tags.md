# Tags And Post-Processing

POSY2 component builders attach Nosy tags so that reporting code can select
components without parsing names. Tags do not change the optimisation model.
They decide **which Excel rows and indicators a component enters** when you
call [`printsnapshot`](@ref).

The practical question is always: *what is the consequence of having this
tag?*

## Tag Kinds

| Kind | Examples | Role |
|:-----|:---------|:-----|
| Component `:function` | `"generation"`, `"storage"`, `"demand"` | Which post-processing family includes the component |
| Component `:tech` | `cname` (e.g. `"Gas"`) | Column label when annual tables aggregate by technology |
| Component `:zone` | principal node name | Regional selection in queries and reports |
| Node tags | `:electricity`, `:hydrogen`, `:foreign`, `:co2` | Which nodes belong to electricity / hydrogen / self-system views |

Annual sheets filter by `:function`, then group columns by `:tech`. The
`Annual values (all)` sheet uses every matching node; `Annual values (self)`
excludes nodes tagged `:foreign` (and components that belong only to them).

Cost tags such as `:investment` or `:fuel` are separate: they label objective
terms for `cost(result, …)`. See [Querying A Snapshot](querying.md).

## Consequence Of `:function`

If a component carries a given `:function` value, standard post-processing
includes it in the blocks below. A component may carry several values at once
(for example a battery is both `"storage"` and `"generation"`).

| `:function` | Consequence in `printsnapshot` / indicators |
|:------------|:--------------------------------------------|
| `"generation"` | Electrical production capacity and yearly net production; CO2 emissions; generation costs, earnings, and average price received. Hourly production series. |
| `"storage"` | Electrical storage charge / discharge / max-level capacity and yearly charge / discharge (on `:electricity` nodes). Hydrogen storage max level (on `:hydrogen` nodes). Hourly charging, discharging, and level series. |
| `"ev"` | Treated like storage for charge / discharge / level blocks, and like demand for driving consumption. Merged with storage in several indicators. |
| `"demand"` | Electrical final consumption (port `input`) when also tagged for electricity reporting; hydrogen demand on hydrogen nodes. Hourly demand series. |
| `"demandresponse"` | Demand-response capacity and yearly output. |
| `"electrolysis"` | Electrolysis capacity and yearly electricity input. Counted in electricity-consumption indicators. |
| `"interconnection"` | Interconnection capacity, flows, losses, congestion, and trade tables; hourly interconnection series. |
| `"nodeinterconnection"` | Subtype of interconnection between two modelled nodes. |
| `"priceinterconnection"` | Subtype of interconnection with an exogenous neighbour price; feeds price-duration curves for that neighbour. |
| `"AC"` / `"DC"` | On node interconnections: AC links enter the DC-OPF cycle basis; DC links are excluded from that basis. |
| `"foreign"` | On interconnections (and related filters): marks a link that crosses the self-system boundary used by the self annual sheet and [`selfcost`](@ref). |
| `"hydrogen"` | Marks hydrogen-side components (demand, purchase, electrolysis, H2 storage) for hydrogen-oriented filters. |
| `"purchase"` | Flat hydrogen purchase components. |
| `"dispatchable"` / `"intermittent"` / `"carbonfree"` / `"virtual"` | Descriptive roles used by builders and filters; they are not separate annual sheet families by themselves. |
| `"curtailment"` | On nodes that are not `rule=:curtailed`, output from components with this tag is summed into the curtailment indicator. Shipped builders do not set it; usual studies rely on `:curtailed` nodes instead. |

Concrete examples:

- `:function => "generation"`  the component appears in the generation
  capacity and production rows of the annual sheets.
- `:function => "storage"`  it appears in the storage
  charge / discharge / level blocks (and hydrogen storage capacity when the
  component sits on a `:hydrogen` node).
- `:function => "electrolysis"`  it appears in electrolysis capacity and
  yearly electricity-use rows, not in the generation production table unless
  it also carries `"generation"`.

Missing or wrong tags usually mean a solved component is absent from Excel
even though balances and costs still look correct in direct Nosy queries.

## Node Tags

| Node tag | Consequence |
|:---------|:------------|
| `:electricity` | Node enters electricity capacity, yearly energy, price, and DC-OPF graph construction. |
| `:hydrogen` | Node enters hydrogen storage capacity lines and hydrogen-side filters. |
| `:foreign` | Node is dropped from the self annual sheet and from [`selfcost`](@ref). |
| `:co2` | CO2 accounting node; not an electricity reporting zone. |

Give each electricity node a distinct carrier name as well as the
`:electricity` tag; interconnection topology uses carriers and ports.

## Default Tags From Builders

Builders set the defaults below. Individual component pages list ports and
naming; this table is the reporting map.

| Builder | Typical `:function` tags |
|:--------|:-------------------------|
| [`makedemand`](@ref) | `electricity`, `demand` |
| [`makeflathydrogendemand`](@ref) / [`makeflexhydrogendemand`](@ref) | `hydrogen`, `demand` |
| [`makeflathydrogenpurchase`](@ref) | `hydrogen`, `purchase` |
| [`makeEV`](@ref) | `electricity`, `demand`, `ev` (+ `generation` when V2G) |
| [`makedemandresponse`](@ref) | `virtual`, `demandresponse` |
| [`makedispatchable`](@ref) / [`makenuclear`](@ref) | `generation`, `dispatchable` |
| [`makeintermittentsource`](@ref) / [`makehydroror`](@ref) | `generation`, `intermittent`, `carbonfree` |
| [`makehydroreservoir`](@ref) | `generation`, `storage`, `carbonfree` |
| [`makebatterystorage`](@ref) | `electricity`, `storage`, `generation` |
| [`makehydrogenstorage`](@ref) | `hydrogen`, `storage` |
| [`makeelectrolyser`](@ref) | `demand`, `electrolysis`, `hydrogen` |
| [`makepriceinterco`](@ref) | `interconnection`, `priceinterconnection` (+ `foreign` if set) |
| [`makenodeinterco`](@ref) | `interconnection`, `nodeinterconnection`, `AC` or `DC` (+ `foreign` if set) |

`:tech` is set from `cname`. `:zone` is set from the principal connected
node (both ends for node interconnections).

## Custom Components

A custom Nosy component is included in POSY2 reports only if its tags (and
conventional port names) match the filters above. The usual fix is either:

1. wrap it in a small POSY2 builder that calls `tag!` like the shipped ones, or
2. tag the component by hand after construction.

See [Extending POSY2](extending.md) for the wrapper pattern. Overriding default
tags through builder keyword arguments is not a standard feature yet; until
then, matching tags (or a dedicated builder) is the supported path.

## Related Pages

- [Querying A Snapshot](querying.md) — `getcomponents` / `getnodes` filters
- [Exporting Results](exporting.md) — workbook sheets produced by `printsnapshot`
- [Component Builders](../components.md) — per-builder ports and tags
- [Building A Snapshot](building-snapshot.md) — when tags are attached
