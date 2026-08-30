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
            discount_rate=0.05,
            co2_price=100.0,
        ),
    ),
)
```

The default `TimeMesh()` is a circular year with 8760 hourly steps. The current
Posy2 data and post-processing conventions assume this yearly hourly horizon.
Nosy supports more general meshes, but several Posy2 builders contain
year-specific logic, so shorter or irregular meshes are not fully supported yet.

## Carriers And Nodes

Component builders expect existing Nosy carriers and nodes. 
Create those first, then pass the nodes into the builders.

```julia
power = EnergyCarrier("electricity", s)
hydrogen = MassCarrier("hydrogen", s; energy=33.33)
heat = EnergyCarrier("heat", s)
carbon = CO2Carrier("CO2", s)

electricity = Node("zone", power; rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
hydrogen_node = Node("hydrogen", hydrogen; tags=[:hydrogen])
heat_node = Node("heat", heat; tags=[:heat])
co2_node = Node("CO2", carbon; rule=:curtailed, tags=[:co2])
```

The `:electricity` tag marks nodes for electricity reporting and for the
optional DC power-flow graph. Tag a node `:foreign` when it should be left
out of self-system views such as the self annual sheet and
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
nodes, and returns it. The returned object can be inspected or extended with 
Nosy before the snapshot is finalised.

### Demand And Flexibility

- [`makedemand`](@ref) combines a scaled hourly demand profile with an optional
  flat annual demand term. `profile_shift` circularly shifts the profile and
  `grid_losses` adds a linked loss flow.
- [`makeflathydrogendemand`](@ref) spreads a yearly hydrogen demand evenly over
  8760 hours.
- [`makeflexhydrogendemand`](@ref) creates a flexible sink whose yearly intake
  is fixed but whose hourly schedule is optimised.
- [`makeEV`](@ref) builds an EV fleet in exactly one mode: fixed profile,
  smart charging, or vehicle-to-grid.
- [`makedemandresponse`](@ref) represents demand response as dispatchable
  negative consumption with an activation cost.

For fixed-profile EV demand, the off-hour sets and minimum off-hour charging
ratio define the annual charging shape. Smart charging and vehicle-to-grid
models take hourly mobility (vehicle departures/arrivals and SOC), plus `number_ev` 
and `initial_connected_share`. Charging availability follows
from the connected fleet. Vehicle-to-grid additionally exposes an output flow
and can apply a discharge compensation cost.

### Hydrogen

- [`makeflathydrogenpurchase`](@ref) creates a flat, fixed yearly hydrogen
  supply.

### Generation

- [`makedispatchable`](@ref) builds a generic dispatchable source with fixed or
  optimisable capacity, fixed and variable costs, optional fuel and CO2 flows,
  ramping, and optional unit commitment.
- [`makenuclear`](@ref) adds nuclear-specific waste cost, integer capacity,
  warm starts, unit-commitment masks, and optional scheduled refuelling shutdowns.
- [`makeintermittentsource`](@ref) combines a weather-year profile with fixed
  or optimisable capacity.
- [`makehydroror`](@ref) creates fixed- or variable-capacity run-of-river hydro
  from an intake profile.

An intermittent source always reads its profile from the selected
`profiles_<year>` sheet. Run-of-river hydro similarly reads a yearly intake
shape, normalises it to sum to one, and applies the requested total intake. It
supports a positive numeric output capacity, a new optimised capacity, or an
external JuMP variable or affine expression bounded by `mincap` and `maxcap`.

Dispatchable and nuclear plants can treat fuel in two ways. With
`fuelnode=nothing`, there is no separate fuel system: generation only adds a
`fuel_cost` on electricity output. With a fuel node, generation draws a linked
fuel input through `efficiency`, so fuel supply, storage, or other fuel uses
can be modelled elsewhere in the same snapshot.

Unit commitment is enabled with `uc=true`. A  positive `unit_size` sets the
fleet unit scale (`0` means no unit-size constraint). `integer_uc=true` makes
commitment decisions integer. With `refuel=true` (the default), nuclear
refuelling constraints are active only together with unit commitment and
require consistent refuel duration, frequency, and mask inputs. Set
`refuel=false` to disable them.

### Storage And Conversion

- [`makebatterystorage`](@ref) builds battery storage with a `power_cap` power
  capacity and duration, with round-trip efficiency, and optional grid losses.
- [`makehydroreservoir`](@ref) represents reservoir intake, pumping,
  generation, and an optional reservoir level capacity. Its capacities are
  exogenous: a finite `energy_cap` fixes the level, and the default `Inf`
  leaves it unlimited.
- [`makehydrogenstorage`](@ref) builds simplified hydrogen storage whose
  `energy_cap` level capacity can be fixed or optimised.
- [`makeelectrolyser`](@ref) converts electricity into hydrogen.

Battery investment is attached to the power capacity. Its duration
behaviour links that power capacity to the storage level. Hydrogen storage
instead attaches investment to the level capacity and deliberately uses
Nosy's simplified storage formulation.

`grid_losses` on demand, batteries, electrolysers, EVs, and reservoir charging
creates an explicit linked loss flow. It is separate from the conversion or
storage efficiency.

## Capacity Choices

Investment builders usually set capacity as follows:

- a number fixes that capacity;
- `nothing` optimises capacity, optionally bounded by `mincap` and `maxcap`;
- an extracted snapshot inherits the capacity of the matching component in it.

Which port that capacity refers to depends on the technology:

- generation uses `output` capacity;
- batteries and electrolysers use `input` capacity;
- hydrogen storage uses `level` capacity;
- reservoirs set `output`, `input` and `level` capacity separately.

### Inheriting capacity from a snapshot

Pass a previous snapshot as the capacity itself to fix a new component to the
value already chosen there—for example to keep an optimised PV fleet while
changing something else in a follow-on study:

```julia
makeintermittentsource("PV", grid, co2, snapshot; tech_column="PV", cap=first_result)
```

Posy2 looks up `name * " " * node_name` in that snapshot, so use the same
component prefix and node name as before. The snapshot must be the result of
`extract`: an optimized but unextracted one still holds JuMP expressions rather
than numbers. A snapshot that is unextracted, has no matching component, or
whose component lacks the relevant port throws an `ArgumentError`.

## Costs And Annualisation

Technology builders turn overnight CAPEX into an annual investment term with
[`eac`](@ref). A connection charge may be added as a fraction of that term.
Builders also attach fixed O&M, decommissioning, variable O&M, fuel, waste,
CO2, no-load, and startup costs when they apply. These are ordinary tagged
Nosy costs and can be selected individually in an objective or report.

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

Most builders name a component by joining `name` and the principal node name
with a space:

```julia
makedispatchable("Gas", electricity, co2_node, snapshot; tech_column="CCGT")
# Component name: "Gas zone"
```

Price interconnections use `IC_<neighbour>_<local-node>`, while node
interconnections use `<name>_<first-node>_<second-node>`.

Builders normally add:

- a `:tech` tag containing `tech`, which defaults to the component name prefix;
- one or more `:zone` tags containing connected zone names;
- `:function` tags such as `"generation"`, `"demand"`, `"storage"`,
  `"interconnection"`, `"hydrogen"`, or a more specific technology role.

The tags support reporting:

```julia
getcomponents(snapshot; with=[:function => "generation"])
getcomponents(
    snapshot;
    with=[:function => "interconnection"],
    without=[:function => "priceinterconnection"],
)
```

Which `:function` values appear in which report blocks is described in
[Tags And Post-Processing](tags.md).

## Interconnections

[`makepricelink`](@ref) represents a neighbouring zone through exogenous
spot prices and directional transfer-capacity profiles. Imports are priced as
positive system costs and exports as negative costs. It is useful when the
neighbour itself is outside the model. `name` identifies the corridor, while
`neighbor` names the counterparty for reports and `neighbor_column` the workbook
columns; both default to `name`. `import_capacity` and `export_capacity` follow
the common capacity contract with their own `mincap`/`maxcap` bounds. Because
the counterparty is not a node that could be tagged `:foreign`, the builder
carries `neighbor_is_foreign` itself.

[`maketransmissionlink`](@ref) connects two explicit Nosy nodes with directional
flows. It applies one shared installed capacity, directional time-varying
transfer-capacity multipliers, losses, transaction costs, fixed capacity costs,
and an optional SOS1 one direction at a time relation on the sending ports
`input` and `input2`.

A node interconnection crosses the boundary used for self-system reporting
exactly when one of its endpoints is a node tagged `:foreign`; there is no
builder flag for this. Set `dc=true` for a controllable DC link. An AC link
participating in the optional DC power flow formulation uses `dc=false` and a
negative `susceptance`. Exactly one AC and one DC may share the same unordered
node pair (either, both, or neither is fine). A second AC or a second DC on
that pair raises an error. Aggregate equivalent parallel circuits before
calling [`maketransmissionlink`](@ref).

The shared capacity uses the common `cap`/`mincap`/`maxcap` contract. Its two
directional limits use the corresponding `From>To` columns of a time-series
sheet as multipliers: `transfer_capacities_AC` for an AC link and
`transfer_capacities_DC` for a DC one. `transfer_capacities` belongs to
[`makepricelink`](@ref). A numeric zero capacity skips both profile lookups;
a zero directional multiplier disables only that direction.

After all components and interconnections have been created, continue with
[Optimising A Snapshot](optimizing.md).
