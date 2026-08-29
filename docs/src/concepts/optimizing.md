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

A DC power flow study calls [`applydcopf!`](@ref) once, after every AC and DC
interconnection has been added and before optimisation. There is no snapshot
option to enable it: the call is what adds the KVL constraints.

```julia
applydcopf!(snapshot)
Nosy.optimize!(snapshot, cost(snapshot))
```

The `method` keyword picks the formalism used to write them, `:cycles`
(default) or `:ptdf`; see [Choosing A Formalism](#Choosing-A-Formalism) below.

Calling it a second time, or adding a node interconnection afterwards, raises
an `ArgumentError`: the constraints already in the model were built from the
earlier topology and cannot be refreshed in place.

Nodal carrier balances and interconnection capacity bounds are already
enforced by the underlying Nosy model; [`applydcopf!`](@ref) only adds the
Kirchhoff voltage law (KVL) constraints that restrict AC flows.

Set each AC link’s series susceptance in [`makenodeinterco`](@ref)
(negative for inductive lines, ``B\approx-1/X``). Use one equivalent
susceptance if parallel AC circuits were aggregated beforehand.
Controllable DC links (`dc=true`) are excluded from the AC network.

### Signed Line Flows

Both formalisms below constrain the same quantity. For a directed AC line
``(i,j)`` and each time step ``t``, they use the signed net midpoint flow

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
``\theta_i-\theta_j=-f_{ij}/B_{ij}``. Posy2 therefore requires a strictly
negative `susceptance` on every AC link of the network.

### Choosing A Formalism

The `method` keyword selects how those angles are eliminated. The two
formalisms are algebraically equivalent—they define the same feasible flows
and give the same solution—so the choice is one of formulation, not of
physics.

```julia
applydcopf!(snapshot; method=:cycles)  # default
applydcopf!(snapshot; method=:ptdf)
```

`:cycles` writes one constraint per independent AC cycle ``C``, taken from a
cycle basis of the AC graph, with the edges of ``C`` oriented consistently with
its traversal:

```math
\sum_{(i,j) \in C} \frac{f_{ij,t}}{B_{ij}} = 0
\qquad \forall\, C,\, t.
```

This is Kirchhoff's voltage law on the nodal angles: the voltage drops around a
loop cancel. It is the smaller formulation, with one constraint per cycle,
that is ``L-N+1`` constraints per time step on a connected AC network of ``L``
lines and ``N`` nodes.

`:ptdf` writes one constraint per AC line ``l``, tying its flow to the net
nodal injections ``p_{n,t}``:

```math
f_{l,t} = \sum_n \mathrm{PTDF}_{l,n}\, p_{n,t}
\qquad \forall\, l,\, t.
```

``\mathrm{PTDF}`` is the power transfer distribution factor matrix
``\mathrm{PTDF} = B_d A \left(A^\top B_d A\right)^{+}``, where ``A`` is the
line-node incidence matrix of the AC graph and ``B_d`` the diagonal matrix of
line susceptances ``-B_{ij}``. Row ``l`` gives the share of an injection at
each node that flows through line ``l``. The pseudo-inverse spreads the slack
over all nodes, so the rows sum to zero and disconnected AC islands need no
separate treatment. The injection ``p_{n,t}`` is the AC flow leaving node
``n``, which the nodal balance ties to the generation, demand and DC transfers
there. This formulation is the more explicit one—it exposes how each nodal
injection loads every line—at the price of ``L`` constraints per time step
instead of ``L-N+1``.

Leave the call out for a transport study. Call it once for a given snapshot; it
is a model-construction step, not part of the solver call.

### Inspecting The Network

Each formalism exposes the object it builds its constraints from:
[`cyclebasis`](@ref) for `:cycles` and [`ptdfmatrix`](@ref) for `:ptdf`. Both
read the topology only, so they can be called before or after
[`applydcopf!`](@ref), whichever `method` was used, and on an extracted result.

```jldoctest network_inspection
julia> using Posy2, Nosy, HiGHS

julia> import JuMP: Model, set_silent

julia> sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1//1, 24)));

julia> set_silent(model(sim))

julia> snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
           data_dir=joinpath(pkgdir(Posy2), "data"),
           tech_mode=:arguments,
           timeseries_mode=:arguments,
       )));

julia> zones = [Node("Z$i", EnergyCarrier("electricity Z$i", sim),
                     rule=:curtailed, tags=[:electricity]) for i in 1:4];

julia> makenodeinterco("IC", zones[1], zones[2], Inf, Inf, snapshot; susceptance=-1.0);

julia> makenodeinterco("IC", zones[2], zones[3], Inf, Inf, snapshot; susceptance=-2.0);

julia> makenodeinterco("IC", zones[3], zones[1], Inf, Inf, snapshot; susceptance=-3.0);

julia> makenodeinterco("HVDC", zones[2], zones[4], Inf, Inf, snapshot; dc=true);

julia> cyclebasis(snapshot)
1-element Vector{Vector{String}}:
 ["Z1", "Z3", "Z2"]

julia> p = ptdfmatrix(snapshot);

julia> p.nodes
4-element Vector{String}:
 "Z1"
 "Z2"
 "Z3"
 "Z4"

julia> p.lines
3-element Vector{Tuple{String, String}}:
 ("Z1", "Z2")
 ("Z2", "Z3")
 ("Z3", "Z1")

julia> round.(p.matrix, digits=4)
3×4 Matrix{Float64}:
  0.2121  -0.2424   0.0303  0.0
 -0.1212   0.4242  -0.303   0.0
 -0.4545   0.0909   0.3636  0.0
```

`Z4` hangs off the HVDC link, which is outside the AC network, so it takes no
share of any AC line and its column is zero. The single AC loop `Z1-Z3-Z2`
closes back onto its first node, so its lines are `Z1-Z3`, `Z3-Z2` and `Z2-Z1`.

The PTDF rows sum to zero: the slack is spread over the nodes, so a factor
means something relative to the others in its row, not on its own. Subtract
column `k` to read the matrix against a single slack node `k` instead. Column
`n` then answers: inject one unit at `n`, withdraw it at the slack. With `Z1`
as slack, column `Z2` on the `Z1 -> Z2` line reads

```jldoctest network_inspection
julia> round((p.matrix .- p.matrix[:, 1])[1, 2], digits=4)
-0.4545
```

Negative because that transfer runs from `Z2` to `Z1`, against the stored
orientation of the row: `0.4545` of it flows `Z2 -> Z1` on the direct line. That
is `1/2.2`, the direct line (``B=-1``) against the `Z1-Z3-Z2` path
(series ``B=-1.2``); the remaining `1.2/2.2` takes the two-line path.

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