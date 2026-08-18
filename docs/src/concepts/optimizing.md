# Optimising A Snapshot

Posy2 builds an optimisation problem in a Nosy snapshot. Solving, status
inspection, extraction, and custom objectives therefore use Nosy and JuMP
directly.

## Objective

Nosy always minimises the objective passed to `Nosy.optimize!`. The usual Posy2
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

If `Posy2Options.dcopf` is true, you must call [`applydcopf!`](@ref) once after
every AC and DC interconnection has been added and before optimisation.
Setting the flag alone does not add KVL constraints:

```julia
applydcopf!(snapshot)
Nosy.optimize!(snapshot, cost(snapshot))
```

Calling it a second time, or adding a node interconnection afterwards, raises
an `ArgumentError`: the constraints already in the model were built from the
earlier topology and cannot be refreshed in place.

Nodal carrier balances and interconnection capacity bounds are already
enforced by the underlying Nosy model; [`applydcopf!`](@ref) only adds the
Kirchhoff voltage law (KVL) constraints that restrict AC flows.

Set each AC link’s series susceptance in [`makenodeinterco`](@ref)
(negative for inductive lines, ``B\approx-1/X``). Use one equivalent
susceptance if parallel AC circuits were aggregated beforehand.
Controllable DC links (`dc=true`) are excluded from the cycle basis.

For each independent AC cycle ``C`` and each time step ``t``, and for a
directed edge ``(i,j)`` oriented consistently with the traversal of ``C``, KVL
uses the signed net midpoint flow

```math
f_{ij,t} =
\frac{f^{i \to j,\mathrm{send}}_t + f^{i \to j,\mathrm{receive}}_t}{2}
-
\frac{f^{j \to i,\mathrm{send}}_t + f^{j \to i,\mathrm{receive}}_t}{2}.
```

With proportional loss factor ``\lambda_{ij}`` in both directions, this is

```math
f_{ij,t} =
\left(1-\frac{\lambda_{ij}}{2}\right)
\left(f^{i \to j,\mathrm{send}}_t-f^{j \to i,\mathrm{send}}_t\right).
```

This reduces to forward minus reverse transfer when `lossfactor=0`.
``B_{ij}`` is the series susceptance of that AC link. For the inductive lines
used here, ``B_{ij}\approx-1/X_{ij}<0``. With the usual lossless DC flow
``f_{ij}=(1/X_{ij})(\theta_i-\theta_j)``, that sign choice makes the angle drop
``\theta_i-\theta_j=-f_{ij}/B_{ij}``, so the cycle constraint

```math
\sum_{(i,j) \in C} \frac{f_{ij,t}}{B_{ij}} = 0
\qquad \forall\, C,\, t.
```

is Kirchhoff's voltage law on those angles. Posy2 therefore requires a strictly
negative `susceptance` on every AC link that enters the cycle basis.

The call is a no-op when `dcopf=false`. Call it once for a given snapshot; it
is a model-construction step, not part of the solver call.

## LP And MILP Models

Continuous capacity expansion and dispatch normally produce an LP. Common
features that make a Posy2 study discrete or otherwise harder to solve include:

- `integercap=true` for nuclear or SMR capacity;
- `integeruc=true` with unit commitment;
- one direction at a time price interconnections using `dir=true`;
- combinations of these decisions over a full 8760-hour horizon.

`uc=true` with `integeruc=false` retains the unit-commitment equations but
relaxes the commitment variables. This can be useful for exploratory studies,
although it is a different mathematical model from integer commitment.

The selected optimiser must support every constraint set used by the study.
In particular, check solver support before enabling SOS1 interconnection
direction constraints (`dir=true` on price or node interconnections).

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
mixed-integer reduced costs as Posy2 node prices.

## Initial Snapshots And Pathways

Pass an extracted snapshot as a capacity argument and the builder uses the
capacity of the matching component in it rather than creating a new investment
decision. This supports dispatch studies based on an existing capacity mix and
sequential pathway calculations. The snapshot must come from `extract`: an
optimized but unextracted snapshot still holds JuMP expressions rather than
numbers, and is rejected with an `ArgumentError`.

```julia
first_result = extract(first_snapshot)

# While building a new snapshot with the same node and component names:
makedispatchable(
    "Gas",
    "CCGT",
    new_grid,
    new_co2,
    new_snapshot;
    cap=first_result,
    # Other technology inputs...
)
```

Matching is based on the generated component name, normally
`"<component prefix> <node name>"`. A snapshot with no matching component
throws an `ArgumentError` naming the capacity keyword and the expected name.

`makedispatchable` and `makenuclear` extend this to unit commitment: `uc=true`
builds commitment from the technology parameters, while passing an extracted
snapshot as `uc` replays the commitment schedule already solved for that
component. Replaying a schedule counts units of the source fleet, so it
requires a capacity fixed to that same fleet — a number, or the same snapshot:

```julia
# Fleet and commitment schedule both frozen: re-solve as an LP, e.g. for duals
makedispatchable("Gas", "CCGT", new_grid, new_co2, new_snapshot;
    cap=first_result, uc=first_result, unit_size=400.0)

# Fleet frozen, commitment re-optimised
makedispatchable("Gas", "CCGT", new_grid, new_co2, new_snapshot;
    cap=first_result, uc=true, unit_size=400.0)
```

Nosy can also optimise several snapshots sharing one simulation and one JuMP
model. This is useful for coupled pathways or stochastic problems, while
inheriting from an extracted snapshot is intended for sequentially fixing
information from an already solved one.