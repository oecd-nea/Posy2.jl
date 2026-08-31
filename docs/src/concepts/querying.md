# Querying A Snapshot

Posy2 snapshots are Nosy snapshots, so the standard Nosy balance, capacity,
cost, price, table, component, and node queries work without an adapter.

## Component Names

Most Posy2 component names combine the component prefix and principal node:

```julia
makedispatchable("Gas", grid, co2_node, snapshot; tech_column="CCGT")
# "Gas grid"

makebatterystorage("Battery", grid, snapshot; tech_column="Li-ion")
# "Battery grid"
```

A price interconnection is named `IC_<neighbour>_<local-node>`. A node
interconnection is named `<prefix>_<first-node>_<second-node>`.

Keep these generated names stable when querying a result or inheriting a
capacity from it in another scenario.

## Capacity

`capacity` returns a component's principal fixed or optimised capacity:

```julia
capacity(result, "Gas grid")
capacity(result, "Battery grid")
capacity(result, "Hydrogen storage hydrogen")
```

The physical meaning depends on the builder. Generation normally reports
output capacity, batteries and electrolysers report input capacity, and
hydrogen storage reports level capacity.

For an overview across components:

```julia
table(result, capacity)
```

Before extraction these calls return JuMP expressions where capacity is a
decision. After extraction they return numeric values.

## Balances

`balance` queries the flows of a component or node over the model horizon. The
sense selects input, output, or storage level, and the modifier selects the
physical view.

```julia
# Annual electricity output.
balance(
    result,
    "Gas grid",
    :output,
    energy;
    collapse=true,
    aggregate=true,
)

# Hourly battery charging.
balance(
    result,
    "Battery grid",
    :input,
    energy;
    collapse=false,
    aggregate=true,
)

# Hourly hydrogen storage level.
balance(
    result,
    "Hydrogen storage hydrogen",
    :level,
    mass;
    collapse=false,
    aggregate=true,
)
```

With `collapse=true`, flow series are integrated over the horizon. Levels
cannot be meaningfully collapsed. With `aggregate=true`, all ports or connected
components matching the selected sense are summed; `:input` selects the input
sense, not a port named `input`. With `aggregate=false`, the separate entries
are retained in a dictionary under their port or component names.

A `MassCarrier` with an energy density can be queried with either `mass` or
`energy`. This is useful for hydrogen models:

```julia
balance(result, "Electrolyser grid", :output, mass;
    collapse=true, aggregate=true)
balance(result, "Electrolyser grid", :output, energy;
    collapse=true, aggregate=true)
```

## Losses

[`losses`](@ref) returns electricity losses by node, source, technology, and
category:

```julia
losses(result)                          # every loss source
losses(result; by=:node)                # total for each node
losses(result; by=(:tech, :category))   # each technology, split by cause
losses(result; collapse=false)          # hourly series
```

The categories are `:node`, `:component`, `:interconnection`, `:storage`, and
`:selfdischarge`. Restrict the result with `categories`, for example:

```julia
losses(result; by=:source, categories=(:interconnection,))
```

Lossless sources are omitted. See [Losses](exporting.md#Losses) for category
definitions, attribution of interconnection losses, and their relationship to
the annual reports.

## Costs

Nosy cost queries expose the terms added by Posy2 builders:

```julia
cost(result)                  # Total system cost.
cost(result, :investment)     # Investment cost across all components.
cost(result, :fuel)           # Fuel cost across all components.
cost(result, "CCGT")          # Total cost of the CCGT.
cost(result, "CCGT", :fuel)   # Fuel cost of the CCGT.
```

Common Posy2 cost tags include `:investment`, `:connection`, `:fom`,
`:decommissioning`, `:vom`, `:fuel`, `:co2`, `:waste`, `:noload`,
`:startup`, `:imports`, `:exports`, and `:transaction`. Only tags used by the
components in a given model appear in its cost table.

Use `costs` to inspect the breakdown by component and cost tag:

```julia
costs(result) # Cost table by component and cost tag.
```

`costs(result)` reports costs as represented in the optimisation objective.
For a study containing foreign nodes or exogenous-price interconnections,
[`selfcost`](@ref) instead evaluates the total attributed to the system
boundary represented by non-foreign electricity nodes:

```julia
selfcost(result) # Total cost attributed to the local system boundary.
```

It excludes components belonging only to foreign nodes and re-evaluates
interconnection imports, exports, and congestion rent from the self-node
perspective. This calculation relies on valid node dual prices and should be
used with an extracted continuous solution whose electricity nodes were
created with `evalprice=true`.

## Prices

For a continuous solution:

```julia
dualprice(result.nodes["grid"]) # Hourly marginal price at the grid node.
```

The sign and unit follow the node-balance convention and the cost and flow
units used by the study. Dual prices are unavailable for mixed-integer
solutions.

Price-based interconnections carry an exogenous neighbour price as variable
import and export costs. These price series are included in Posy2's standard
workbook post-processing alongside endogenous electricity-node prices.

## Querying Problems

An optimisation problem can be queried in the same way as an extracted
solution, except for prices. Use the original snapshot in place of `result`:

```julia
capacity(snapshot, "Gas grid")
balance(snapshot, "Gas grid", :output, energy; collapse=true, aggregate=true)
cost(snapshot)
```

Quantities that depend on decision variables are returned as JuMP expressions
instead of numbers. Prices are the exception because dual prices only exist
after solving a continuous model.

Symbolic queries are useful when building higher-order algorithms that inspect
or reuse model quantities, including iterative loops, multi-level optimisation,
and search heuristics.

## Tags And Filtering

Posy2 component builders add tags so that reporting code can select components
by function, technology, and zone.

```julia
generation = getcomponents(
    result;
    with=[:function => "generation"],
)

local_storage = getcomponents(
    result;
    with=[:function => "storage", :zone => "grid"],
    without=[:function => "foreign"],
)
```

Electricity and foreign-node tags are supplied when the nodes are created:

```julia
electricity_nodes = getnodes(result; with=[:electricity])
self_nodes = getnodes(
    result;
    with=[:electricity],
    without=[:foreign],
)
```

A generator usually has one `:zone`. A node interconnection has two—one for
each endpoint—so zone filters can find interconnections connected to a zone.

```julia
grid_node_ics = getcomponents(
    result;
    with=[:function => "nodeinterconnection", :zone => "grid"],
)
```

For the reporting consequence of each `:function` and node tag—which annual
rows and indicators include a tagged component—see
[Tags And Post-Processing](tags.md).

## Standard Reports

[`write_results`](@ref) generates the full Posy2 post-processing workbook,
including annual values, time series, and price duration curves:

```julia
write_results(result, "results/scenario.xlsx")
```

See [Exporting Results](exporting.md) for its output path and file
replacement policy.
