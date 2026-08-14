# Extending Posy2

This page is about building custom Posy2 component builders on top of the
Nosy compositional API: assemble a Nosy physical model, attach
optimisation behaviours, then wrap the result with Posy2 naming and tags so
querying and post-processing recognise it. Existing builders such as
[`makedispatchable`](@ref) and [`makeelectrolyser`](@ref) are complete examples
of that pattern—open them once the design steps below are clear.

## Design Flow

Every Posy2 technology follows the same sequence:

1. Physical model — choose a Nosy archetype, carriers, and ports.
2. Behaviours — attach capacity, costs, linked flows, and other constraints.
3. Posy2 wrapper — set the component name, tags, and `connect!` the ports.
4. Reporting — inspect with `capacity`, `balance`, and `cost`, and rely on
   annual tables that filter by `:function` and aggregate by `:tech`.

A pure Nosy component already has physics and behaviours. Posy2 adds the
wrapper so the object uses the same naming and tagging rules as the shipped
builders. Compatible tags and ports are what let Posy2 queries and
[`printsnapshot`](@ref) place the component with generation, storage, or
interconnections.

## Common Design Questions

Before writing Julia, answer these questions. They decide the archetype,
behaviours, and whether an existing builder already covers the role.

- Does it supply, consume, store, or convert carriers?
- If it consumes: is the load a fixed series, a capacity*profile shape, or flexible?
- If it stores: is charge / discharge / level enough, or are extra flows
  needed (inflow, driving, losses)?
- How many inputs and outputs are there, and on which carriers / nodes?
- Is capacity defined on the input, the output, or a storage level?
- Is a state (`level`) required?
- Are there linked flows—fuel, CO2, grid losses, heat?
- Should capacity be fixed, or an investment decision?
- Are there fixed costs on capacity and variable costs on flows?
- Does an existing builder already cover this modelling role?

An existing builder that already solves the same role is usually the clearest
starting point.

## Choose The Physical Model

Ask what the technology is in Nosy terms, then check that the node carriers
and port names match that choice. Nosy physical models fall into four
groups:

- Source — supplies a carrier through `output`.
- Sink — consumes a carrier through `input` (the demand / load side).
- Storage — carries a `level` state over time, with charge/discharge-style
  ports.
- Converter — transforms one carrier into another (`input` -> `output`).

### Nosy archetypes

| Group | Archetype | Typical use |
|:------|:----------|:------------|
| Source | `DispatchableSource` | Flexible supply (thermal plant, ...) |
| Source | `ProfileSource` | Capacity * availability profile (PV, wind, flat purchase, ...) |
| Sink | `Demand` | Fixed consumption series (usual electricity / H2 load) |
| Sink | `ProfileSink` | Capacity * consumption profile (mandatory capacity on `input`) |
| Sink | `BasicSink` | Flexible consumption; mirrors `DispatchableSource` |
| Storage | `BasicStorage` | Charge / discharge / level on one machine (battery, H2 store, ...) |
| Storage | `LazyStorage` | Level plus joint flows for extra ports (hydro inflow, EV driving, ...) |
| Converter | `BasicConverter` | One-to-one conversion (electrolyser, node interconnection, ...) |

Posy2 builders already wrap most of these. `Demand`, `DispatchableSource`,
`ProfileSource`, `BasicSink`, `BasicStorage`, `LazyStorage`, and
`BasicConverter` appear in shipped `make...` functions. `ProfileSink` is still
a valid Nosy choice for a custom builder when a fixed `Demand` series is not
enough—for example a capacity-shaped load.

Port naming follows [Component Builders](../components.md): sources use
`output`; sinks and converters use `input`; storage normally uses `input` /
`output` / `level` (`LazyStorage` may add further ports as joint flows);
linked carrier flows use names such as `fuel`, `co2`, and `grid losses`.

Some Posy2 builders compose archetypes with joint flows. Demand response uses
a zero `Demand` host plus a linked negative input; interconnections reuse
these archetypes ([`makenodeinterco`](@ref) uses `BasicConverter`,
[`makepriceinterco`](@ref) uses `DispatchableSource`).

| Builder | Archetype | Capacity port(s) | Typical costs on | Typical `:function` |
|:--------|:----------|:-----------------|:-----------------|:--------------------|
| [`makedispatchable`](@ref) | `DispatchableSource` | `output` | `output` (+ fuel / CO2) | `generation` |
| [`makeintermittentsource`](@ref) | `ProfileSource` | `output` | `output` | `generation` |
| [`makedemand`](@ref) | `Demand` | — | — | `demand` |
| [`makebatterystorage`](@ref) | `BasicStorage` | `input` (power) | `input` | `storage` |
| [`makehydrogenstorage`](@ref) | `BasicStorage` | `level` | `level` | `storage` |
| [`makehydroreservoir`](@ref) | `LazyStorage` | `output` / `input` / `level` | `output` | `storage` |
| [`makeEV`](@ref) | `Demand` (fixed) or `LazyStorage` (smart / V2G) | mode-dependent | V2G VOM on `output` | `demand` / `ev` / ... |
| [`makeelectrolyser`](@ref) | `BasicConverter` | `input` | `input` | `electrolysis`, ... |
| [`makeflathydrogenpurchase`](@ref) | `ProfileSource` | `output` | — | `hydrogen`, `purchase` |
| [`makedemandresponse`](@ref) | zero `Demand` + linked negative input | `output` (unconnected) | `output` | `demandresponse`, `virtual` |

See [Component Builders](../components.md) for the full catalogue and the exact
ports each builder connects. For archetype details beyond Posy2 wrappers, see
the Nosy documentation.

## Choose Behaviours

The physical model decides what the technology is. Behaviours decide how it
behaves in the optimisation problem. They attach to ports—add only what
the study needs. Not every behaviour belongs on every archetype; it depends on
which ports exist (or which ports you add with joint flows).

```text
DispatchableSource              # can produce on output
  + FixedCapacity               # caps maximum output
  + VariableCost(:vom, ...)      # makes that output costly
  + VariableCost(:fuel, ...)     # prices fuel as a scalar cost
  # or LinkedJointFlow("fuel", ...) when fuel is a physical flow to another node
```

Posy2 builders mostly draw from the behaviours below. For anything beyond this
set, see the Nosy documentation. Posy2 `cap` / `nothing` conventions are in
[Component Builders](../components.md); input units and workbook lookups are in
[Input Workbooks](input-data.md).

### Capacity

Attach capacity to the port that represents the technology's plant size.

- `FixedCapacity(port, energy, value)` — known size on that port.
- `VariableCapacity(port, energy)` — capacity as a decision (optional bounds
  as keywords when needed).

In Posy2, that plant-size port is often `output` for generation, `input` for
battery or electrolyser power, and `level` for hydrogen storage energy. Hydro
may size more than one port. `capacity(result, "...")` reads the capacity on
that same port. See also [Capacity Semantics](../components.md#Capacity-Semantics).

### Costs

- `FixedCost(tag, port, energy, coeff)` — prices capacity (`:investment`,
  `:fom`, connection, decommissioning, ...). Attach it to the same port as the
  plant-size capacity.
- `VariableCost(tag, port, energy, coeff)` — prices a flow (`:vom`, `:fuel`,
  imports, ...).

Tags are what `cost(result, …)` and annual tables use.

### Availability and sizing links

- `CapacityMultiplier(port, series)` — scales available capacity over time
  (intermittent availability, EV plugged-in share, price-IC limits).
- `Duration(hours)` — links storage energy capacity to power capacity
  (battery-style).

### Joint flows

Use these when you need extra ports or a proportional link to another carrier.

- `LinkedJointFlow` — new port is a function of another (CO2 or fuel from
  generation `output`, grid losses from `input`). Connect the new port to the
  right node.
- `FreeJointFlow` — adds a flexible port (LazyStorage charge/discharge, IC
  reverse direction).
- `FixedJointFlow` — adds a port driven by a fixed series (hydro inflow, EV
  driving).

`LazyStorage` starts with `level`; charge, discharge, and side flows are
usually added this way before capacity or cost goes on those ports.

### Annual totals and operations

- `YearlySum` — constrains the annual total of a flow (flexible hydrogen
  demand).
- `Ramping` — limits how fast a flexible port can change.
- `UnitCommitment` — on/off (or fleet) commitment; often paired with startup
  and no-load costs on generation builders such as
  [`makedispatchable`](@ref) and [`makenuclear`](@ref).

## Builder Template

The example below fills in the [Design Flow](#Design-Flow) for a simple
load-shifting case. The wrapper step is split into naming, tags, and
`connect!`. It reuses the battery `BasicStorage` machine and prices the
shifting flow (opex) instead of capacity (capex). That approximates load
shifting via net load; a fixed `Demand` series itself does not move. Swap the
archetype, behaviours, and tags for other technologies.

```julia
function makeloadshifting(cname::String, elec::Node, s::Snapshot;
    power_cap::Real, duration::Real, shift_cost::Real,
)
    # 1. Physical model — BasicStorage: charge / discharge / level
    #    (same Nosy machine as a battery; eff_i=1 means no round-trip loss)
    m = BasicStorage(elec.carrier; eff_i=1.0)

    # 2. Behaviours — only what this technology needs
    vb = []
    push!(vb, Duration(duration))                          # energy stock <-> power
    push!(vb, FixedCapacity("input", energy, power_cap))   # max shifting power
    # no FixedCost(:investment, ...) — flexibility is not a capex asset here
    push!(vb, VariableCost(:vom, "input", energy, shift_cost))  # cost on the shifting flow

    # 3. Component with the Posy2 name convention
    c = Component("$cname $(elec.name)", m, vb)

    # 4. Tags that querying and post-processing rely on
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    tag!(c, :function, "demand")        # demand side role
    tag!(c, :function, "loadshifting")  # custom label for filters / reports
    tag!(c, :function, "virtual")

    # 5. Register and connect ports to the correct node
    connect!(s, c, elec)
    return c
end
```

The same steps can be written inline for a study object. A `make...`
function helps when the technology is reused across scenarios, shared with
others, or must appear consistently in Posy2 reports.

## Posy2 Wrapper Conventions

### Component names

Except for interconnections, builders normally name components
`"$cname $(principal_node.name)"`. That string is what
`capacity(result, ...)`, `balance(result, ...)`, and `cost(result, ...)` look up, and
what `ini` inheritance matches between scenarios. Names are unique inside a
snapshot.

### Tags

| Tag | Set from | Role |
|:----|:---------|:-----|
| `:tech` | `cname` | Column label in annual tables; filter key for `getcomponents` |
| `:zone` | principal node name | Regional selection |
| `:function` | modelling role | Post-processing family (`generation`, `storage`, `demand`, `interconnection`, ...) |

Annual post-processing filters by `:function`, then aggregates by `:tech`.
The full consequence map (which tag enters which report block) is in
[Tags And Post-Processing](tags.md). Node tags (`:electricity`, `:hydrogen`,
`:foreign`) also matter for reporting filters; see
[Querying A Snapshot](querying.md). Workbook parameter columns versus the
`:tech` reporting label are covered in [Component Builders](../components.md).

> Note:
> These are the usual places to look when a custom component solves but does
> not show up where you expect, or when capacity, balance, or cost queries
> look off.
>
> - `:function`: annual sheets select components by modelling role
>   (`generation`, `storage`, ...).
> - Archetype: storage needs a `level`; extra side flows often mean
>   `LazyStorage`; flexible consumption is not the same as a fixed `Demand`
>   series.
> - Carriers and port names: connect each port to a node of the matching
>   carrier, using conventional names (`output`, `input`, `level`, ...).
> - Plant-size port: capacity (and fixed costs on capacity) sit on the
>   port that represents plant size for that technology.
> - `connect!`: the component joins nodal balances only after its ports are
>   connected.
> - Unique names: lookups and `ini` inheritance key off the component
>   name.
> - `:tech` and `:zone`: filters and annual aggregation group by these
>   tags.
>
> Related pages: [Component Builders](../components.md), [Building A
> Snapshot](building-snapshot.md), [Querying A Snapshot](querying.md),
> [Tags And Post-Processing](tags.md), [Exporting Results](exporting.md), and
> the [Nosy documentation](https://oecd-nea.github.io/Nosy.jl/dev/).