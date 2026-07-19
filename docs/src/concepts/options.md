# Study Configuration

[`POSY2Options`](@ref) stores the assumptions that apply to the whole POSY2
study. The object is attached to a Nosy `Snapshot` under the `:posy` key:

```julia
using POSY2
using Nosy
using HiGHS

s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())

options = POSY2Options(
    data_dir=joinpath(pwd(), "data"),
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:excel,
    timeseries_mode=:excel,
    discountrate=0.05,
    co2_price=100.0,
    dcopf=false,
)

snapshot = Snapshot(s, Dict(:posy => options))
```

Every POSY2 component builder expects this entry to exist, even when all
technology inputs are supplied directly and no workbook is read.
[`posy_options`](@ref) validates and returns it:

```julia
posy_options(snapshot)
discountrate(snapshot)
co2_price(snapshot)
tech_mode(snapshot)
timeseries_mode(snapshot)
```

## Input Modes

Technology parameters and hourly series have independent input switches:

| Option | `:excel` (default) | `:arguments` |
|:-------|:-------------------|:-------------|
| `tech_mode` | Missing technology keywords are read from `techdata_file` | Every technology value used by a builder must be supplied explicitly |
| `timeseries_mode` | Missing series keywords are read from `timeseries_file` | Every series used by a builder must be supplied explicitly |

An explicit builder keyword always wins, in either mode. In `:arguments` mode,
an omitted value raises a targeted `ArgumentError`; POSY2 does not attempt to
open the corresponding workbook. The defaults remain `:excel` for backward
compatibility.

The switches can be mixed. For example, this configuration keeps shared
technology assumptions in Excel while defining scenario profiles in Julia:

```julia
options = POSY2Options(
    tech_mode=:excel,
    timeseries_mode=:arguments,
)
snapshot = Snapshot(s, Dict(:posy => options))

makeintermittentsource(
    "Solar", "Solar PV", electricity, co2, snapshot;
    cap=100.0,
    profile=solar_capacity_factor,
)
```

For a workbook-free study, select `:arguments` for both sources:

```julia
options = POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    discountrate=0.05,
    co2_price=0.0,
)
```

## Workbook Paths

`data_dir` is the directory containing the input files. `techdata_file` and
`timeseries_file` are filenames relative to that directory. POSY2 joins these
values only when a workbook-backed parameter or time series is requested.

```julia
options = POSY2Options(
    data_dir="/path/to/scenario",
    techdata_file="technology_2050.xlsx",
    timeseries_file="timeseries_2050.xlsx",
)
```

Technology parameters are normally loaded when a builder keyword is `nothing`.
Supplying a numeric or string keyword overrides that workbook value. This makes
it possible to keep a common workbook and vary a small number of assumptions
between scenarios.

Profile-backed builders expose direct series keywords as well. A profile can
be an hourly vector matching the simulation mesh, or a scalar that POSY2
expands across the whole mesh. See [Input Workbooks](input-data.md) for the
complete mapping between builder keywords and workbook columns.

See [Input Workbooks](input-data.md) for the workbook layout and exact lookup
keys.

## Economic Assumptions

`discountrate` is used when builders annualise overnight investment and
decommissioning costs. [`eac`](@ref) combines the overnight cost, construction
profile, asset lifetime, and discount rate into an equivalent annual cost.
Construction profiles can be provided as one numeric value or as a
semicolon-separated sequence whose entries sum approximately to one.

```julia
eac(4_000_000.0, discountrate(snapshot), 60, "0.3;0.4;0.3")
```

The technology builders apply the resulting annual cost through Nosy fixed-cost
behaviours. They use separate cost tags for investment, connection, fixed
operation and maintenance, decommissioning, variable operation and
maintenance, fuel, CO2, startup, no-load operation, and other
technology-specific terms.

`co2_price` is the default carbon price passed to emitting generation
builders. When `co2_emission` is non-zero, the builder creates a linked CO2
output port, connects it to the supplied CO2 node, and applies the carbon price
to that flow. A builder-specific `co2price` keyword can override the study
default.

## Optional DC Power Flow

The `dcopf` flag controls whether [`applydcopf!`](@ref) adds Kirchhoff voltage
law constraints. Setting the flag does not add constraints by itself.

For a DC power-flow study:

1. Set `dcopf=true` in `POSY2Options`.
2. Build electricity nodes with the `:electricity` tag.
3. Build AC node interconnections with [`makenodeinterco`](@ref),
   `dc=false`, and a negative `susceptance`.
4. Build any controllable DC links with `dc=true`.
5. Call `applydcopf!(snapshot)` once, after all interconnections have been
   added and before optimisation.

```julia
options = POSY2Options(dcopf=true)
snapshot = Snapshot(s, Dict(:posy => options))

makenodeinterco(
    "line",
    node_a,
    node_b,
    Inf,
    Inf,
    snapshot;
    dc=false,
    susceptance=-10.0,
)

applydcopf!(snapshot)
Nosy.optimize!(snapshot, cost(snapshot))
```

POSY2 constructs an undirected graph from AC node interconnections and adds
one KVL relation for each independent cycle. A tree has no cycle constraint.
Interconnections tagged as DC are excluded because their flow is controllable
and does not obey the AC cycle equations.

The susceptance registry is stored in `snapshot.options[:ic_susceptance]`.
This entry is managed by [`makenodeinterco`](@ref); users should not need to
create it directly.

When `dcopf=false`, `applydcopf!` returns without changing the model. Calling it
in every study therefore provides one consistent build sequence for both
transport and DC power-flow formulations.
