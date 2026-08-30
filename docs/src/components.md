# Component Builders

Posy2 component builders assemble common energy-system technologies from Nosy
archetypes, behaviours, and joint flows. A builder creates a component, adds it
to a snapshot, connects its compatible ports, attaches reporting metadata, and
returns the component.
Builders are a convenience layer on Nosy, not a closed API: 
if a study needs a custom formulation, build it with Nosy directly.

The builders are grouped by modelling role:

- [Demand And Flexibility](components/demand.md) covers
  [`makedemand`](@ref), hydrogen demand, and demand response.
- [Generation](components/generation.md) covers dispatchable, nuclear,
  intermittent, and hydro sources.
- [Storage](components/storage-conversion.md) covers reservoirs and batteries.
- [Electric Vehicles](components/electric-vehicles.md) covers fixed-profile,
  smart-charging, and vehicle-to-grid operation.
- [Interconnections](components/interconnections.md) covers links between
  explicit nodes and links represented by an exogenous price series.
- [Hydrogen](components/hydrogen.md) covers exogenous hydrogen purchase,
  electrolysers, and hydrogen storage.

## Common Arguments

Most builders start with a component name, one or more nodes, and a snapshot.
These names and the common technology keywords have distinct purposes:

- `name` is the prefix used in the generated component name.
- `tech` is the technology label stored in the component's `:tech` tag. Reports
  and component queries group or filter by this value; it defaults to `name`.
- `tech_column` is an exact technology column in the relevant technology
  workbook sheet. Parameter names occupy rows in the column headed `tech`;
  `tech_column` is not a row name. It defaults to `tech`, except for documented
  domain-specific defaults.
- A zone argument selects a column in a time-series sheet. It need not equal a
  node name unless the builder's documented column convention requires that.
- Nodes determine the carriers and balances to which the component is
  connected.
- The snapshot owns the component and supplies [`Posy2Options`](@ref).

Except for interconnections, a builder normally names its component by joining
`name` and the principal node name with a space. For example,
`makedispatchable("CCGT", elec, co2, snapshot)` creates
`"CCGT $(elec.name)"`.
Names must be unique within a snapshot. Interconnection names are described on
the [Interconnections](components/interconnections.md) page.

## Keyword Overrides

When `tech_mode=:excel`, a technology keyword left as `nothing` is read from
the `tech_column` column. When `timeseries_mode=:excel`, a series keyword left as
`nothing` is read from the time-series workbook. An explicit value replaces
that lookup for this call only; it does not edit the workbook. Sheet layout
and unit conversions are in [Input Workbooks](concepts/input-data.md).

## Capacity Semantics

Every user-supplied `cap` or similar capacity argument normally follows this
contract. [`makehydroreservoir`](@ref) is the one exception: its capacities are
exogenous, accepting only a number or an extracted snapshot, and it takes no
bounds.

| Value | Capacity used by the builder | Effect of `mincap` and `maxcap` |
|:------|:-----------------------------|:--------------------------------|
| number | Fixed at that number | Checked as assertions |
| `nothing` | New capacity decision | Bounds on the new decision |
| JuMP `VariableRef` or `AffExpr` | Reuses that external expression | Constraints on the expression |
| extracted `Snapshot` | Fixed at the matching solved capacity | Checked as assertions |

An external expression must use variables owned by the snapshot's JuMP model.
Reusing the same expression in several builders shares one decision; every
builder's bounds constrain that same expression. The individual builder page
states which port the capacity measures. For example, generation capacity is
on `output`, battery and electrolyser capacity is on `input`, and hydrogen
storage capacity is on `level`.

A capacity inherited from a snapshot is looked up by generated component name
and port, so component prefixes and principal node names must agree between
scenarios. The snapshot must come from `extract`, since inheriting reads solved
values. An unextracted snapshot, a missing component, or a component without
the relevant port is an error.

A fixed capacity of zero builds the component and its port at zero capacity.
A builder may nevertheless skip input lookup for an inactive branch: zero
intermittent capacity does not require a production profile, zero hydro intake
does not require an intake profile, and a zero node-interconnector capacity
does not require either directional availability series. Two arguments use `Inf` as an
unlimited-capacity sentinel:

- `energy_cap=Inf` in [`makehydroreservoir`](@ref), its default, leaves the
  stored-energy level unlimited by adding no level capacity behavior.
- `cap=Inf` in [`makedemandresponse`](@ref) leaves response output unlimited.
  `cap=nothing` creates a capacity decision and emits a warning suggesting
  `Inf` when unlimited capacity was intended.

A symbolic capacity is treated as structurally active because its optimized
value is not known while the component is built. A symbolic node-interconnector
capacity therefore resolves both directional availabilities even if the
expression later evaluates to zero. Price interconnections apply the same rule
to each separate directional capacity and also resolve their price input.

`unit_size`, `integer_cap`, and `integer_uc` control discrete formulations where
the relevant builder supports them. Their applicability and combined behavior
are described in
[Note On Capacity And Unit Commitment](components/generation.md#Note-On-Capacity-And-Unit-Commitment).
These options may turn an LP into a MILP.

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

## Reading The Port Diagrams

Each builder page carries a diagram of the component it builds. Input-sense
ports are on the left, output-sense ports on the right, and arrows always point
in the direction energy travels. A stored-energy level, when the component has
one, is drawn inside the component box. Colour and line style encode what
determines a flow:

| Style | Meaning |
|:------|:--------|
| solid teal | free flow: the optimizer chooses it, subject to its capacity |
| dashed dark blue | fixed flow: an exogenous series imposes it |
| dotted orange | linked flow: it is a function of another flow, such as `grid losses` |
| red | stored energy level, with its capacity; the arrow measuring it from zero is teal, since the level is itself a decision |

A solid box is a node the port is connected to, tinted by carrier: pale yellow
for electricity, pale red for heat, pale blue for hydrogen, grey otherwise. A
dashed box marks a port that is not connected, either because an input series
feeds it or because it releases energy outside the system. Annotations under
each arrow name the capacity and efficiency arguments that act on that port.
