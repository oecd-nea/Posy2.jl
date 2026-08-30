# Tags And Post-Processing

Posy2 component builders attach Nosy tags so that reporting code can select
components without parsing names. Tags do not change the optimisation model.
They decide which report rows and indicators a component enters when you
call [`printsnapshot`](@ref).

## Tag Kinds

| Kind | Examples | Role |
|:-----|:---------|:-----|
| Component `:function` | `"generation"`, `"storage"`, `"demand"` | Which post-processing family includes the component |
| Component `:tech` | `tech` (e.g. `"Gas"`) | Column label when annual tables aggregate by technology |
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
| `"foreign"` | On price interconnections only: marks a link whose priced counterparty is outside the self-system boundary. Node interconnections carry no such component tag; their boundary crossing is derived from the connected nodes' `:foreign` tags. |
| `"hydrogen"` | Marks hydrogen-side components (demand, purchase, electrolysis, H2 storage) for hydrogen-oriented filters. |
| `"dispatchable"` / `"intermittent"` / `"carbonfree"` / `"virtual"` / `"purchase"` | Descriptive roles used by builders and filters; they are not separate annual sheet families by themselves. |
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

Missing or wrong tags usually mean a solved component is absent from the
workbook report even though balances and costs still look correct in direct
Nosy queries.

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

Builders set the component tags below. Individual component pages list ports
and naming; this table is the reporting map.

| Builder | `:function` values | Other tags |
|:--------|:-------------------|:-----------|
| [`makedemand`](@ref) | `electricity`, `demand` | `:tech => tech`, `:zone => n.name` |
| [`makeflathydrogendemand`](@ref) | `hydrogen`, `demand` | `:tech => tech`, `:zone => n.name` |
| [`makeflexhydrogendemand`](@ref) | `hydrogen`, `demand` | `:tech => tech`, `:zone => n.name` |
| [`makeflathydrogenpurchase`](@ref) | `hydrogen`, `purchase` | `:tech => tech`, `:zone => n.name` |
| [`makeEV`](@ref) | `electricity`, `demand`, `ev`; also `generation` when `vehicle_to_grid=true` | `:tech => tech`, `:zone => elec.name` |
| [`makedemandresponse`](@ref) | `virtual`, `demandresponse` | `:tech => tech`, `:zone => elec.name` |
| [`makedispatchable`](@ref) | `generation`, `dispatchable` | `:tech => tech`, `:zone => elec.name` |
| [`makenuclear`](@ref) | `generation`, `dispatchable` | `:tech => tech`, `:zone => elec.name` |
| [`makeintermittentsource`](@ref) | `generation`, `intermittent`; also `carbonfree` when `co2_emission` is zero | `:tech => tech`, `:zone => elec.name` |
| [`makehydroror`](@ref) | `generation`, `intermittent`, `carbonfree` | `:tech => tech`, `:zone => elec.name` |
| [`makehydroreservoir`](@ref) | `generation`, `storage`, `carbonfree` | `:tech => tech`, `:zone => elec.name` |
| [`makebatterystorage`](@ref) | `electricity`, `storage`, `generation` | `:tech => tech`, `:zone => elec.name` |
| [`makehydrogenstorage`](@ref) | `hydrogen`, `storage` | `:tech => tech`, `:zone => h2.name` |
| [`makeelectrolyser`](@ref) | `demand`, `electrolysis`, `hydrogen` | `:tech => tech`, `:zone => elec.name` |
| [`makepricelink`](@ref) | `interconnection`, `priceinterconnection`; also `foreign` when `neighbor_is_foreign=true` | `:neighbor => neighbor`, `:zone => elec.name` |
| [`maketransmissionlink`](@ref) | `interconnection`, `nodeinterconnection`, and `AC` or `DC` | `:zone => a.name`, `:zone => b.name` |

## Custom Components

A custom Nosy component is included in Posy2 reports only if its tags (and
conventional port names) match the filters above. The usual fix is either:

1. wrap it in a small Posy2 builder that calls `tag!` like the shipped ones, or
2. tag the component by hand after construction.

See [Extending Posy2](extending.md) for the wrapper pattern. Builders that set a
`:tech` tag accept `tech` to override their reporting technology label; other
tags are set by the builder's modelling role.

## Related Pages

- [Querying A Snapshot](querying.md) — `getcomponents` / `getnodes` filters
- [Exporting Results](exporting.md) — workbook sheets produced by `printsnapshot`
- [Component Builders](../components.md) — per-builder ports and tags
- [Building A Snapshot](building-snapshot.md) — when tags are attached
