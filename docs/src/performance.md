# Performance

In most POSY2 studies, computation time is dominated by the optimiser rather
than by the component builders. The most important performance decisions are
therefore the temporal horizon, use of integer variables, interconnection
formulation, and solver configuration.

## Work With Functions

The usual Julia performance guidance applies: put model construction and
reporting code inside functions, keep input types stable, and avoid repeatedly
reconstructing identical intermediate data.

```julia
function build_scenario(optimizer, options)
    s = Sim(Model(optimizer); mesh=TimeMesh())
    snapshot = Snapshot(s, Dict(:posy => options))
    # Build carriers, nodes, and components.
    return snapshot
end
```

See Julia's
[Performance Tips](https://docs.julialang.org/en/v1/manual/performance-tips/)
for general advice.

## Workbook Reads

POSY2 caches workbook reads using the path, filename, and file modification
time. Technology sheets are also cached because converting an
Excel table to a DataFrame can be noticeable in a large build.

Keep scenario workbooks unchanged while a model is being built. Editing a file
changes its modification time and correctly causes POSY2 to read it again.
Supplying explicit builder overrides can avoid lookups for scalar parameters,
but profile-driven builders still require their time-series data.

## Variable Names

Explicit JuMP variable names help diagnose infeasibility, but name creation can
be noticeable in very large models. Disable string names immediately after
creating the simulation if they are not needed:

```julia
import JuMP

s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
JuMP.set_string_names_on_creation(model(s), false)
```

Do this before building components. Keep names enabled while developing or
when solver conflict reports are part of the workflow.

## Integer Decisions

Integer unit commitment is usually the largest increase in solve difficulty.
Use `integeruc=true` only when discrete commitment is important to the study.
The relaxed formulation with `uc=true, integeruc=false` is faster but is not
equivalent to integer commitment.

Integer nuclear capacity decisions (`integercap=true`) also turn the
capacity expansion into a MILP. Large unit sizes can make the investment
problem combinatorial even when dispatch itself is simple.

For nuclear unit commitment, use `startupmask` and `shutdownmask` to avoid
creating event choices at timesteps where transitions are not allowed.
Nuclear reload masks should similarly reflect the actual set of permissible
reload windows.

## Interconnections

For price interconnections, `dir=true` adds one SOS1 relation per timestep so
that imports and exports cannot occur simultaneously. This can increase solver
work. The current node-interconnection implementation of `dir=true` can
suppress all transfer; leave it disabled until the constraint is corrected.

The optional DC power flow formulation adds one KVL relation per independent
cycle of the AC network, not one relation for every possible cycle. Tree
networks therefore receive no additional KVL constraints. DC links are
excluded from the AC cycle graph.

Call [`applydcopf!`](@ref) only after the network is complete and only once per
snapshot.

## Storage Simplifications

[`makebatterystorage`](@ref) and [`makehydroreservoir`](@ref) expose a
`simplified=true` option that selects Nosy's simpler storage balance
formulation. [`makehydrogenstorage`](@ref) always uses the simplified
formulation because it is intended for medium- or long-term inventory.

The simplified formulation changes the temporal representation of storage.
Validate it against the default formulation when storage operation is central
to the result.

## Time Horizon

Nosy supports custom and heterogeneous time meshes, but current POSY2 builders
and standard post-processing contain several explicit 8760-hour assumptions.
Use the default yearly hourly `TimeMesh()` for complete POSY2 studies unless
every selected builder and report has been checked for a custom horizon.

Reducing the horizon solely for a quick structural prototype can still be
useful when the chosen builders are mesh-compatible, but such a run is not an
approximation of annual costs, storage cycles, unit commitment, or seasonal
profiles.

## Nosy Model Cleanup

Nosy exposes model-generation options through `Sim`. These include objective
coefficient cleanup, constraint scaling, small-bound cleanup, and the ability
to disable the scaling bridge.

```julia
s = Sim(
    HiGHS.Optimizer;
    mesh=TimeMesh(),
    objthreshold=1e-8,
    constraint_scaling=true,
    expthreshold=0.0,
    scalingtarget=1.0,
    boundthreshold=0.0,
)
```

The default zero thresholds preserve the mathematical model. Positive
thresholds may remove small but meaningful terms when model units differ
substantially, so validate any cleanup setting before production use.

## Reporting

[`printsnapshot`](@ref) computes a broad collection of annual and hourly
tables before writing the workbook. For repeated interactive analysis, query
only the required Nosy metrics and generate the full workbook once at the end
of the study.

Price and self-system reports require evaluated node duals. If they are not
needed, omitting `evalprice=true` avoids retaining those additional results.
