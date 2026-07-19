# Querying A Snapshot

POSY2 snapshots are Nosy snapshots, so the standard Nosy balance, capacity,
cost, price, table, component, and node queries work without an adapter.

## Component Names

Most POSY2 component names combine the component prefix and principal node:

```julia
makedispatchable("Gas", "CCGT", grid, co2_node, snapshot)
# "Gas grid"

makebatteries("Battery", "Li-ion", grid, snapshot)
# "Battery grid"
```

A price interconnection is named `IC_<neighbour>_<local-node>`. A node
interconnection is named `<prefix>_<first-node>_<second-node>`.

Keep these generated names stable when querying a result or using an `ini`
snapshot in another scenario.

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
cannot be meaningfully collapsed. With `aggregate=false`, separate named ports
or connected components are retained in a dictionary.

A `MassCarrier` with an energy density can be queried with either `mass` or
`energy`. This is useful for hydrogen models:

```julia
balance(result, "Electrolyser grid", :output, mass;
    collapse=true, aggregate=true)
balance(result, "Electrolyser grid", :output, energy;
    collapse=true, aggregate=true)
```

## Costs

Nosy cost queries expose the terms added by POSY2 builders:

```julia
cost(result)
cost(result, :investment)
cost(result, :fuel)
cost(result, "Gas grid")
costs(result)
```

Common POSY2 cost tags include `:investment`, `:connection`, `:fom`,
`:decommissioning`, `:vom`, `:fuel`, `:co2`, `:waste`, `:noload`,
`:startup`, `:imports`, `:exports`, and `:transaction`. Only tags used by the
components in a given model appear in its cost table.

`costs(result)` reports costs as represented in the optimisation objective.
For a study containing foreign nodes or exogenous-price interconnections,
[`selfcost`](@ref) instead evaluates the total attributed to the system
boundary represented by non-foreign electricity nodes:

```julia
selfcost(result)
```

It excludes components belonging only to foreign nodes and re-evaluates
interconnection imports, exports, and congestion rent from the self-node
perspective. This calculation relies on valid node dual prices and should be
used with an extracted continuous solution whose electricity nodes were
created with `evalprice=true`.

## Prices

For a continuous solution:

```julia
price = dualprice(result.nodes["grid"])
minimum(price)
maximum(price)
sum(price) / length(price)
```

The sign and unit follow the node-balance convention and the cost and flow
units used by the study. Dual prices are unavailable for mixed-integer
solutions.

Price-based interconnections carry an exogenous neighbour price as variable
import and export costs. These price series are included in POSY2's standard
Excel post-processing alongside endogenous electricity-node prices.

## Tags And Filtering

POSY2 component builders add tags so that reporting code can select components
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

Filtering by tags is preferable to parsing names, particularly for
interconnections that belong to two zones.

## Standard Reports

[`printsnapshot`](@ref) generates the full POSY2 post-processing workbook,
including annual values, time series, and price duration curves:

```julia
printsnapshot(result, "scenario.xlsx")
```

See [Exporting Results](exporting.md) for its output location and file
replacement behaviour.
