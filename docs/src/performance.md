# Performance

In most Posy2 studies, computation time is dominated by the optimiser rather
than by the component builders. The most important performance decisions are
therefore the temporal horizon, use of integer variables, interconnection
formulation, and solver configuration.

If model construction itself becomes noticeable, the usual Julia advice
applies: put model construction and reporting code inside functions, keep
input types stable, and avoid repeatedly reconstructing identical intermediate
data. See Julia's
[Performance Tips](https://docs.julialang.org/en/v1/manual/performance-tips/)
for general advice.

```julia
function build_scenario(optimizer, options)
    s = Sim(Model(optimizer); mesh=TimeMesh())
    snapshot = Snapshot(s, Dict(:posy => options))
    # Build carriers, nodes, and components.
    return snapshot
end
```

Posy2 caches workbook reads using the path, filename, and file modification
time. Technology sheets are also cached because converting a workbook table to a
DataFrame can be noticeable in a large build. Keep scenario workbooks unchanged
while a model is being built; editing a file changes its modification time and
correctly causes Posy2 to read it again. Supplying explicit builder overrides
can avoid lookups for scalar parameters, but profile-driven builders still
require their time-series data.

In problems with a very large number of variables, JuMP string names can take
a non-negligible time. Names help diagnose infeasibility, but if they are not
needed, disable them immediately after creating the simulation and before
building components:

```julia
import JuMP

s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
JuMP.set_string_names_on_creation(model(s), false)
```

Keep names enabled while developing or when solver conflict reports are part
of the workflow.

## Constraint Scaling

Nosy applies its constraint-scaling bridge only when `Sim` receives an
optimiser constructor. Pass `HiGHS.Optimizer` directly when configuring
`constraint_scaling`, `scalingtarget`, or `expthreshold`:

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

The sections below mostly target solver time by reducing model size or
changing formulation choices in Posy2 builders.

## Integer Decisions

Integer unit commitment is usually the largest increase in solve difficulty.
Use `integer_uc=true` only when discrete commitment is important to the study.
The relaxed formulation with `uc=true, integer_uc=false` is faster but is not
equivalent to integer commitment.

Integer nuclear capacity decisions (`integer_cap=true`) also turn the
capacity expansion into a MILP. Large unit sizes can make the investment
problem combinatorial even when dispatch itself is simple.

For nuclear unit commitment, use `startupmask` and `shutdownmask` to avoid
creating event choices at timesteps where transitions are not allowed.
Nuclear refuel masks should similarly reflect the actual set of permissible
refuelling windows.

## Interconnections

For price and node interconnections, `exclusive_direction=true` adds one SOS1 relation per
timestep so that the two directions cannot be used simultaneously. This can
increase solver work.

The optional DC power flow formulation adds one KVL relation per independent
cycle of the AC network, not one relation for every possible cycle. Tree
networks therefore receive no additional KVL constraints. DC links are
excluded from the AC cycle graph.


## Storage Simplifications

[`makebatterystorage`](@ref) and [`makehydroreservoir`](@ref) expose a
`simplified=true` option that selects Nosy's simpler storage balance
formulation. [`makehydrogenstorage`](@ref) always uses the simplified
formulation because it is intended for medium- or long-term inventory.

The simplified formulation changes the temporal representation of storage.
Validate it against the default formulation when storage operation is central
to the result.

## Time Horizon

Posy2 builders require a full non-leap year of 8760 hours and reject any other
horizon, so the model cannot be made smaller by shortening the year.

Only the number of hours is constrained, so a mesh that aggregates steps, such
as `TimeMesh(fill(2 // 1, 4380))`, is accepted. It is not a free approximation.
Nosy attaches a value to each step boundary instead of averaging it over the
step, so an hourly series given to a coarser mesh is sampled at those
boundaries and whatever happens between them is dropped. On a two-hour mesh the
annual total of a series becomes twice the sum of its even-numbered hours:
every second hour is counted twice and the hours between are dropped. The error
is therefore set by the shape, not by the mesh. A flat series survives
unchanged, which makes `annual_flat_demand` and the flat hydrogen quantities
exact on any mesh; a one-hour peak on an odd hour disappears entirely, and the
same peak an hour later doubles.

For a demand profile, a capacity factor, an availability or a spot price this
is ordinary resolution loss: the mesh represents the supplied data less finely,
which is what a coarser mesh does. An annual total a builder is asked to reach
is different in kind, because the shape is normalized to hit that total and the
total should hold whatever the mesh. The hydro `intake` is normalized against
the integral over the mesh and is delivered exactly at any resolution.

[`makeEV`](@ref) is the exception still standing. It is the builder that writes
its own shape, a square wave switching at the end of the `offhours` window, and
it normalizes that shape against the hour grid. `offhours1=0:6` switches at hour
7, which a two-hour mesh never samples, and loses 4.3% of `annual_consumption`;
`offhours1=0:7` switches at hour 8 and is exact. Six-hour steps lose 21.7%.

Aggregate steps only for profiles the coarser grid resolves, and compare the
annual totals given to the builders against the solved result. The controls that
count time are unaffected: Nosy accumulates the step weights, so `min_uptime`,
`min_downtime`, `startup_duration`, `shutdown_duration` and `refuel_duration`
cover the hours they name on any mesh, rounded up to the step that reaches them,
and the ramp allowance is scaled by the step weight so the rate stays the same
per hour.

Nuclear refuelling is the one schedule Posy2 constrains itself rather than
handing to Nosy. [`makenuclear`](@ref) walks the steps of the mesh and places
the allowed outage starts on the hour grid `refuel_slot_spacing` defines, so
`refuel_slot_spacing=730` opens about twelve starts whatever the step length. A
mesh coarser than the spacing cannot resolve every start and opens fewer, which
is resolution loss rather than a changed requirement: the number of outages
`refuel_fraction_per_year` asks for is enforced on any mesh.

## Reporting

[`printsnapshot`](@ref) computes a broad collection of annual and hourly
tables before writing the workbook. For repeated interactive analysis, query
only the required Nosy metrics and generate the full workbook once at the end
of the study.

Price and self-system reports require evaluated node duals. If they are not
needed, omitting `evalprice=true` avoids retaining those additional results.
