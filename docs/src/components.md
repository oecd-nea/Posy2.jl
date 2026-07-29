# Component Builders

POSY2 component builders assemble common energy-system technologies from Nosy
archetypes, behaviours, and joint flows. A builder creates a component, adds it
to a snapshot, connects its compatible ports, attaches reporting metadata, and
returns the component. This gives studies a consistent vocabulary without
preventing direct use of Nosy when a custom formulation is needed.

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

Most builders start with a component name, a technology name, one or more
nodes, and a snapshot. These names have distinct purposes:

- `cname` is the technology label used in the component name and its `:tech`
  tag. Annual reports group components by this value.
- `tech` is an exact **technology column** in the relevant technology workbook
  sheet. Parameter names occupy rows in the column headed `tech`; `tech` is not
  a row name.
- A zone argument selects a column in a time-series sheet. It need not equal a
  node name unless the builder's documented column convention requires that.
- Nodes determine the carriers and balances to which the component is
  connected.
- The snapshot owns the component and supplies [`POSY2Options`](@ref).

Except for interconnections, a builder normally names its component by joining
`cname` and the principal node name with a space. For example,
`makedispatchable("CCGT", ..., zone, ...)` creates `"CCGT $(zone.name)"`.
Names must be unique within a snapshot. Interconnection names are described on
the [Interconnections](components/interconnections.md) page.

## Workbook Defaults And Keyword Overrides

An optional technical or economic keyword set to `nothing` is normally read
from the technology column selected by `tech`. Passing a value overrides that
one workbook cell. This makes it possible to share a central assumption set and
change only the values that define a sensitivity.

Supplying every technology parameter explicitly avoids technology-workbook
lookups for many builders. Profile-based builders still need their time-series
columns. [`makedemand`](@ref) skips its profile lookup when `coeff=0`, and an
unlimited direction of [`makenodeinterco`](@ref) skips the corresponding
transfer-capacity lookup. See [Input Workbooks](concepts/input-data.md) for the
complete sheet, row, and column conventions.

POSY2 treats the following inputs consistently across the costed builders:

- `overnight_cost` and `om_fixed_cost` are multiplied by 1,000 before they are
  attached to a capacity. With the usual MW convention, their input units are
  USD/kW and USD/kW/year.
- `om_var_cost`, `fuel_cost`, and similar flow costs are normally in USD/MWh.
- `construction_profile` and `decommissioning_profile` are either `1.0` for a
  one-year profile or semicolon-separated non-negative shares such as
  `"0.3;0.4;0.3"`. The shares must sum approximately to one.
- `connection_cost` and `decommissioning` are ratios. The former is applied to
  annualised investment; the latter determines total decommissioning cost as a
  fraction of overnight cost.
- `co2_emission` is divided by 1,000 to form the linked CO2 flow, while the CO2
  flow is priced with `co2price`.

POSY2 remains unit-agnostic in the same sense as Nosy: a study may use another
consistent unit system, but the conversions above are part of the builders and
must be accounted for.

## Capacity Semantics

For builders with a `cap`, `capin`, or similar capacity keyword, a number
usually creates a fixed capacity and `nothing` creates a capacity decision.
`mincap` and `maxcap` apply only to that decision. Important exceptions are
documented with each builder:

- `makedispatchable(...; cap=0)` omits the component and returns `nothing`.
- [`makehydroror`](@ref) requires a positive fixed capacity because it
  normalises an absolute inflow series by that value.
- A zero charging capacity in [`makehydroreservoir`](@ref) disables grid
  charging rather than creating a zero-capacity input port.
- `capa=nothing` in [`makedemandresponse`](@ref) leaves response output without
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

Capacity and cost behaviours are attached to the port named on each component
page. This matters when querying a solved snapshot: a battery's investment is
attached to `input`, while a dispatchable plant's investment is attached to
`output`.

## Tags And Reporting

Builders add metadata used by POSY2 post-processing. Most components receive
one `:tech` value, a `:zone` value, and one or more `:function` values. Common
function tags include `generation`, `demand`, `storage`, `electrolysis`,
`interconnection`, and `foreign`.

Node tags are equally important. Electricity nodes should carry
`:electricity`, hydrogen nodes should carry `:hydrogen`, and modelled external
zones should also carry `:foreign`. Interconnection topology is inferred from
connected ports and carrier names, so distinct electricity nodes should use
distinct carrier names.

Custom Nosy components are valid in a POSY2 snapshot. To include them in POSY2
reports, give them compatible tags and conventional port names. The individual
component pages list the tags created by each builder. For the design sequence
when adding a technology—physical model, behaviours, naming, tags, and
connection—see [Extending POSY2](concepts/extending.md).

