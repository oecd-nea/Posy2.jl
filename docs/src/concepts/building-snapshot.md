# Building A Snapshot

This page covers the objects used to describe a Posy2 study before solving:
the Nosy simulation and snapshot, carriers and nodes, Posy2 component builders,
cost assumptions, names and tags, initial snapshots, and interconnections.

## Simulation And Snapshot

Nosy owns the JuMP model and time mesh. Posy2 stores its study configuration in
the Nosy snapshot and adds components to that same model.

```julia
using Posy2
using Nosy
using HiGHS

s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
snapshot = Snapshot(
    s,
    Dict(
        :posy => Posy2Options(
            discountrate=0.05,
            co2_price=100.0,
            dcopf=false,
        ),
    ),
)
```

The default `TimeMesh()` is a circular year with 8760 hourly steps. The current
Posy2 data and post-processing conventions assume this yearly hourly horizon.
Nosy supports more general meshes, but several Posy2 builders contain
year-specific logic and should not yet be treated as mesh-agnostic.

## Carriers And Nodes

Component builders expect existing Nosy carriers and nodes. 
Create those first, then pass the nodes into the builders.

```julia
power = EnergyCarrier("electricity", s)
hydrogen = MassCarrier("hydrogen", s; energy=33.33)
heat = EnergyCarrier("heat", s)
carbon = CO2Carrier("CO2", s)

electricity = Node(
    "zone",
    power;
    rule=:curtailed,
    evalprice=true,
    losses=0.0,
    tags=[:electricity],
)
hydrogen_node = Node("hydrogen", hydrogen; tags=[:hydrogen])
heat_node = Node("heat", heat; tags=[:heat])
co2_node = Node(
    "CO2",
    carbon;
    rule=:curtailed,
    tags=[:co2],
)
```

The `:electricity` tag is used by Posy2 post-processing and the optional
DC power flow graph. Tag external neighbour nodes with `:foreign`; leave nodes
inside the system boundary without that tag. This distinction is also used by
[`selfcost`](@ref).

`evalprice=true` tells Nosy to store the node's electricity marginal price
(the dual of the power balance constraint) after a continuous solve. Enable it
if the node's price will be used later, for example in price reports or
price-based interconnection accounting.

A node with `rule=:curtailed` allows supply to exceed consumption. The default
balanced node requires exact equality. Choose the rule according to
the commodity and whether free curtailment is meaningful.

## Component Builders

Each Posy2 builder assembles one Nosy model archetype with the required
behaviours and joint flows, creates a component, tags it, connects it to the
supplied nodes, and returns it. The returned object can be inspected or
extended with Nosy before the snapshot is finalised.

### Demand And Flexibility

- [`makedemand`](@ref) combines a scaled hourly demand profile with an optional
  flat annual demand term. `shift` circularly shifts the profile and
  `gridlosses` adds a linked loss flow.
- [`makeflathydrogendemand`](@ref) spreads a yearly hydrogen demand evenly over
  8760 hours.
- [`makeflexhydrogendemand`](@ref) creates a flexible sink whose yearly intake
  is fixed but whose hourly schedule is optimised.
- [`makeEV`](@ref) supports one of three mutually exclusive modes: fixed
  charging, smart charging, or vehicle-to-grid operation.
- [`makedemandresponse`](@ref) represents demand response as dispatchable
  virtual supply with an activation cost.

For fixed-profile EV demand, the off-hour sets and minimum off-hour charging
ratio define the annual charging shape. Smart charging and vehicle-to-grid
models use charging-availability and driving profiles from the time-series
workbook. Vehicle-to-grid additionally exposes an output flow and can apply a
discharge compensation cost.

### Hydrogen

- [`makeflathydrogenpurchase`](@ref) creates a flat, fixed yearly hydrogen
  supply.

### Generation

- [`makedispatchable`](@ref) builds a generic dispatchable source with fixed or
  optimisable capacity, fixed and variable costs, optional fuel and CO2 flows,
  ramping, and optional unit commitment.
- [`makenuclear`](@ref) adds nuclear-specific waste cost, integer capacity,
  warm starts, unit-commitment masks, and optional scheduled reload shutdowns.
- [`makeintermittentsource`](@ref) combines a weather-year profile with fixed
  or optimisable capacity.
- [`makehydroror`](@ref) creates fixed-capacity run-of-river hydro from an
  inflow profile.

An intermittent source always reads its profile from the selected
`profiles_<year>` sheet. Run-of-river hydro similarly reads a yearly inflow
series and requires a positive numeric capacity because the profile is
normalised by that capacity.

Dispatchable and nuclear sources can represent fuel in two ways. With
`fuelnode=nothing`, fuel is a variable cost on electricity output. With a fuel
node, the builder creates a linked input flow using the supplied or
workbook-backed efficiency. The latter formulation allows fuel supply to be
modelled and constrained elsewhere in the same snapshot.

Unit commitment is enabled with `uc=true`. A non-zero `unit_size` defines the
fleet unit scale, while `integeruc=true` turns commitment decisions into
integer variables. Nuclear reload constraints are only active together with
unit commitment and require consistent reload duration, frequency, and mask
inputs.

### Storage And Conversion

- [`makebatterystorage`](@ref) builds battery storage with charging-power capacity,
  a duration relation, round-trip efficiency, and optional grid losses.
- [`makehydroreservoir`](@ref) represents reservoir inflow, pumping,
  generation, and a fixed reservoir level capacity.
- [`makehydrogenstorage`](@ref) builds simplified hydrogen storage whose level
  capacity can be fixed or optimised.
- [`makeelectrolyser`](@ref) converts electricity into hydrogen.

Battery investment is attached to the charging-power capacity. Its duration
behaviour links that power capacity to the storage level. Hydrogen storage
instead attaches investment to the level capacity and deliberately uses
Nosy's simplified storage formulation.

`gridlosses` on demand, batteries, electrolysers, EVs, and reservoir charging
creates an explicit linked loss flow. It is separate from the conversion or
storage efficiency and should not be counted a second time in reporting.

## Capacity Choices

Investment builders usually set capacity as follows:

- a number fixes that capacity;
- `nothing` optimises capacity, optionally bounded by `mincap` and `maxcap`;
- an `ini` snapshot (normally a solved result) can replace the new decision
  with capacity inherited from a matching component.

Which port that capacity refers to depends on the technology:

- generation uses `output` capacity;
- batteries and electrolysers use `input` capacity;
- hydrogen storage uses `level` capacity.

Some builders have extra rules (for example how `cap=0` is handled), so check
the individual API entry when writing shared study code.

### Inheriting capacity with `ini`

Matching uses Posy2's generated component names. Build the new scenario with
the same component prefix (`cname`) and node name as in the initial snapshot.
Prefer an extracted result for `ini` over an unsolved snapshot, so the
inherited capacity values are already numeric.

## Costs And Annualisation

Technology builders convert overnight cost into an annual fixed investment
term with [`eac`](@ref). They also add the applicable connection, fixed O&M,
decommissioning, variable O&M, fuel, waste, CO2, no-load, and startup terms.
These are ordinary tagged Nosy costs and can be selected individually in an
objective or report.

```julia
cost(snapshot)
cost(snapshot, :investment)
cost(snapshot, :fuel)
```

When a keyword is `nothing`, its value is normally read from the technology
workbook. Supplying every required technology keyword makes that builder
independent of the technology workbook. Profile-driven builders may still
need the time-series workbook. See [Input Workbooks](input-data.md) for the
lookup rules.

## Names And Tags

Most builders name a component by joining `cname` and the principal node name
with a space:

```julia
makedispatchable("Gas", "CCGT", electricity, co2_node, snapshot)
# Component name: "Gas zone"
```

Price interconnections use `IC_<neighbour>_<local-node>`, while node
interconnections use `<cname>_<first-node>_<second-node>`.

Builders normally add:

- a `:tech` tag containing the component name prefix;
- one or more `:zone` tags containing connected zone names;
- `:function` tags such as `"generation"`, `"demand"`, `"storage"`,
  `"interconnection"`, `"hydrogen"`, or a more specific technology role.

The tags support reporting without parsing component names:

```julia
getcomponents(snapshot; with=[:function => "generation"])
getcomponents(
    snapshot;
    with=[:function => "interconnection"],
    without=[:function => "foreign"],
)
```

Which `:function` values appear in which report blocks is described in
[Tags And Post-Processing](tags.md).

## Interconnections

[`makepriceinterco`](@ref) represents a neighbouring zone through exogenous
spot prices and directional transfer-capacity profiles. Imports are priced as
positive system costs and exports as negative costs. It is useful when the
neighbour itself is outside the model.

[`makenodeinterco`](@ref) connects two explicit Nosy nodes with directional
flows. It can apply directional capacities, time-varying transfer-capacity
multipliers, losses, transaction costs, and an optional SOS1 one direction at a time
relation. The current node-interconnection implementation of that relation
can suppress all transfer; leave `dir=false` until the limitation described in
[Interconnections](../components/interconnections.md) is corrected.

Set `foreign=true` when a node interconnection crosses the boundary used for
self-system reporting. Set `dc=true` for a controllable DC link. An AC link
participating in the optional DC power flow formulation uses `dc=false` and a
negative `susceptance`. Exactly one AC and one DC may share the same unordered
node pair (either, both, or neither is fine). A second AC or a second DC on
that pair raises an error. Aggregate equivalent parallel circuits before
calling [`makenodeinterco`](@ref).

Finite directional capacities on node interconnections use the corresponding
`From>To` columns of the `transfer_capacities` time-series sheet as
multipliers. Passing `Inf` removes that directional capacity and its profile
lookup.

After all components and interconnections have been created, continue with
[Optimising A Snapshot](optimizing.md).
