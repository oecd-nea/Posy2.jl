# Optimising A Snapshot

POSY2 builds an optimisation problem in a Nosy snapshot. Solving, status
inspection, extraction, and custom objectives therefore use Nosy and JuMP
directly.

## Objective

Nosy always minimises the objective passed to `Nosy.optimize!`. The usual POSY2
objective is total annual system cost:

```julia
Nosy.optimize!(snapshot, cost(snapshot))
```

Cost tags can be selected or combined when a study needs a different
objective:

```julia
Nosy.optimize!(
    snapshot,
    cost(snapshot, :investment) +
    cost(snapshot, :fuel) +
    cost(snapshot, :co2),
)
```

To maximise a scalar affine expression, minimise its negative:

```julia
Nosy.optimize!(snapshot, -capacity(snapshot, "Wind zone"))
```

The objective can include custom JuMP expressions and constraints. Import only
the JuMP names that are needed, because JuMP and Nosy both define an
`optimize!` function.

```julia
import JuMP: @constraint

@constraint(
    model(sim(snapshot)),
    capacity(snapshot, "Gas zone") <= 5_000.0,
)
Nosy.optimize!(snapshot, cost(snapshot))
```

## DC Power Flow

When `POSY2Options.dcopf` is true, call [`applydcopf!`](@ref) after every AC
and DC interconnection has been added and before optimisation:

```julia
applydcopf!(snapshot)
Nosy.optimize!(snapshot, cost(snapshot))
```

The call adds KVL constraints for the independent cycles of the AC
interconnection graph. It is a no-op when `dcopf=false`. Call it once for a
given snapshot; it is a model-construction step, not part of the solver call.

## LP And MILP Models

Continuous capacity expansion and dispatch normally produce an LP. Common
features that make a POSY2 study discrete or otherwise harder to solve include:

- `integercap=true` for nuclear or SMR capacity;
- `integeruc=true` with unit commitment;
- one direction at a time price interconnections using `dir=true`;
- combinations of these decisions over a full 8760-hour horizon.

`uc=true` with `integeruc=false` retains the unit-commitment equations but
relaxes the commitment variables. This can be useful for exploratory studies,
although it is a different mathematical model from integer commitment.

The selected optimiser must support every constraint set used by the study.
In particular, check solver support before enabling SOS1 interconnection
direction constraints. The current node-interconnection implementation of
`dir=true` can suppress all transfer; see
[Interconnections](../components/interconnections.md).

## Extracting Results

After optimisation, call `extract` to create a snapshot populated with numeric
solution values:

```julia
Nosy.optimize!(snapshot, cost(snapshot))
result = extract(snapshot)
```

The original `snapshot` remains the mathematical problem. The extracted
`result` is the normal object for reporting, cost tables, balances, and
[`printsnapshot`](@ref).

Check the solver status before relying on an extracted result:

```julia
import JuMP

JuMP.termination_status(model(sim(snapshot)))
JuMP.primal_status(model(sim(snapshot)))
```

When a problem is infeasible or no solution is available, `extract` warns and
returns the problem rather than fabricated numeric results. Nosy's conflict
tools can be used with solvers that support irreducible infeasible subsystem
analysis.

## Prices And Integer Solutions

Electricity marginal prices are node-balance dual values. Set
`evalprice=true` when creating the relevant node and solve a continuous model
before calling `dualprice`.

Dual prices are not defined for a mixed-integer solution. If prices are needed
after a MILP investment or commitment solve, a common workflow is:

1. solve the MILP;
2. extract its capacity and commitment decisions;
3. rebuild a continuous dispatch problem with those decisions fixed;
4. solve the continuous problem with price evaluation enabled.

The exact fixing strategy is study-dependent. Do not interpret a solver's
mixed-integer reduced costs as POSY2 node prices.

## Initial Snapshots And Pathways

Many capacity builders accept an `ini` keyword. When supplied, the builder
uses the capacity of a matching component from the initial snapshot rather
than creating a new investment decision. This supports dispatch studies based
on an existing capacity mix and sequential pathway calculations.

```julia
first_result = extract(first_snapshot)

# While building a new snapshot with the same node and component names:
makedispatchable(
    "Gas",
    "CCGT",
    new_grid,
    new_co2,
    new_snapshot;
    ini=first_result,
    # Other technology inputs...
)
```

Matching is based on the generated component name, normally
`"<component prefix> <node name>"`. Behaviour differs slightly when an initial
component is absent, so consult the individual builder API when constructing
generic multi-stage code.

Nosy can also optimise several snapshots sharing one simulation and one JuMP
model. This is useful for coupled pathways or stochastic problems, while
`ini` is intended for sequentially fixing information from an already solved
snapshot.
