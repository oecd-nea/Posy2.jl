# Component Builders

Posy2 component builders assemble common energy-system technologies from Nosy
archetypes, behaviours, and joint flows. A builder creates a component, adds it
to a snapshot, connects its compatible ports, attaches reporting metadata, and
returns the component. The result is a consistent vocabulary across studies. 
Builders are a convenience layer on Nosy, not a closed API: 
if a study needs a custom formulation, build it with Nosy directly.

The builders are grouped by modelling role:

- [Demand And Flexibility](components/demand.md) covers
  [`makedemand`](@ref), hydrogen demand, electric vehicles, and demand
  response.
- [Generation](components/generation.md) covers dispatchable, nuclear,
  intermittent, and hydro sources.
- [Hydrogen](components/hydrogen.md) covers exogenous hydrogen purchase.
- [Storage And Conversion](components/storage-conversion.md) covers
  reservoirs, batteries, hydrogen storage, and electrolysers.
- [Interconnections](components/interconnections.md) covers links between
  explicit nodes and links represented by an exogenous price series.

## Common Arguments

Most builders start with a component name, a technology-data key, one or more
nodes, and a snapshot. These names have distinct purposes:

- `cname` is the technology label used in the component name and its `:tech`
  tag. Annual reports group components by this value.
- `techkey` is an exact technology column in the relevant technology
  workbook sheet. Parameter names occupy rows in the column headed `tech`;
  `techkey` is not a row name.
- A zone argument selects a column in a time-series sheet. It need not equal a
  node name unless the builder's documented column convention requires that.
- Nodes determine the carriers and balances to which the component is
  connected.
- The snapshot owns the component and supplies [`Posy2Options`](@ref).

Except for interconnections, a builder normally names its component by joining
`cname` and the principal node name with a space. For example,
`makedispatchable("CCGT", ..., zone, ...)` creates `"CCGT $(zone.name)"`.
Names must be unique within a snapshot. Interconnection names are described on
the [Interconnections](components/interconnections.md) page.

## Keyword Overrides

When `tech_mode=:excel`, a technology keyword left as `nothing` is read from
the `techkey` column. When `timeseries_mode=:excel`, a series keyword left as
`nothing` is read from the time-series workbook. An explicit value replaces
that lookup for this call only; it does not edit the workbook. Sheet layout
and unit conversions are in [Input Workbooks](concepts/input-data.md).

## Capacity Semantics

For builders with a `cap` or similar capacity keyword, a number
usually creates a fixed capacity and `nothing` makes capacity a decision
variable. `mincap` and `maxcap` bound that variable when capacity is
optimised; they are unused when capacity is fixed. Important exceptions are
documented with each builder:

- `makedispatchable(...; cap=0)` omits the component and returns `nothing`.
- [`makehydroror`](@ref) also accepts a JuMP variable or affine expression as
  an externally defined capacity; `mincap` and `maxcap` bound that expression.
- A zero charging capacity in [`makehydroreservoir`](@ref) disables grid
  charging rather than creating a zero-capacity input port.
- `cap_reservoir=nothing` in [`makehydroreservoir`](@ref) optimises the
  stored-energy capacity; its default `Inf` leaves the level unlimited.
- `cap=nothing` in [`makedemandresponse`](@ref) leaves response output without
  a capacity limit.

Builders with an `ini` keyword can inherit a capacity from a solved snapshot.
The lookup uses the generated component name, so names and principal node names
must agree between scenarios. Missing-component behaviour is builder-specific;
use the individual API entry when constructing sequential scenarios.

`unit_size`, `integercap`, and `integeruc` control discrete formulations where
the relevant builder supports them. These options may turn an LP into a MILP.

## Ports And Connections

The main Nosy ports follow a consistent naming scheme:

- a source delivers through `output`;
- a demand or converter consumes through `input`;
- a storage component normally uses `input`, `output`, and `level`;
- linked carrier flows use names such as `fuel`, `co2`, `heat`, and
  `grid losses`;
- a bidirectional node interconnection uses `input` for the first-to-second
  direction and `input2` for the reverse direction.

Capacity and cost behaviours are attached to a specific port, not to the
component as a whole. When you query a solved snapshot, use the port named on
that builder's page. For example, a dispatchable plant's investment sits on
`output`, while a battery's investment sits on `input`.

## Tags And Reporting

Builders add metadata used by Posy2 post-processing. Most components receive
one `:tech` value, a `:zone` value, and one or more `:function` values. Common
function tags include `generation`, `demand`, `storage`, `electrolysis`,
`interconnection`, and `foreign`.

Node tags are equally important. Electricity nodes should carry
`:electricity`, hydrogen nodes should carry `:hydrogen`, and modelled external
zones should also carry `:foreign`. Interconnection topology is inferred from
connected ports and carrier names, so distinct electricity nodes should use
distinct carrier names.

Custom Nosy components are valid in a Posy2 snapshot. To include them in Posy2
reports, give them compatible tags and conventional port names. The individual
component pages list the tags created by each builder. For which tags select
which report rows, see [Tags And Post-Processing](concepts/tags.md). For the
design sequence when adding a technology—physical model, behaviours, naming,
tags, and connection—see [Extending Posy2](concepts/extending.md).
