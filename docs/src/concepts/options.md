# Study Configuration

[`Posy2Options`](@ref) stores the assumptions that apply to the whole Posy2
study. The object is attached to a Nosy `Snapshot` under the `:posy` key:

```julia
using Posy2
using Nosy
using HiGHS

s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())

options = Posy2Options(
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

Every Posy2 component builder expects this entry to exist, even when all
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

Technology parameters and hourly series have independent input switches.

| Option | `:arguments` (default) | `:excel` |
|:-------|:-----------------------|:---------|
| `tech_mode` | Builders use their documented argument defaults; values without a safe default must be supplied explicitly | Missing technology keywords are read from `techdata_file` |
| `timeseries_mode` | Builders use documented neutral profiles; structural series must be supplied explicitly | Missing series keywords are read from `timeseries_file` |

An explicit builder keyword always wins, in either mode. In `:arguments` mode,
Posy2 does not attempt to open the corresponding workbook. An omitted value
uses the builder's documented neutral default when one exists; a conditionally
required value raises a targeted `ArgumentError`. Both input modes default to
`:arguments`; select `:excel` explicitly when workbook fallback is desired.

For [`makedispatchable`](@ref), economic coefficients and emissions default to
zero, linked-fuel efficiency defaults to one, and unit sizing and ramping are
disabled. A non-zero `overnight_cost` requires `lifetime` and
`construction_profile`; non-zero overnight and decommissioning costs also
require `decommissioning_profile`. Unit commitment and non-zero fractional
ramping require a positive `unit_size`.

The switches can be mixed. For example, this configuration keeps shared
technology data in a workbook while defining scenario profiles in Julia:

```julia
options = Posy2Options(
    tech_mode=:excel,
    timeseries_mode=:arguments,
)
snapshot = Snapshot(s, Dict(:posy => options))

# With electricity / co2 nodes already on the snapshot:
makeintermittentsource(
    "Solar", "Solar PV", electricity, co2, snapshot;
    cap=100.0,
    profile=repeat(
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
         0.125, 0.25, 0.5, 0.75, 1.0, 1.0,
         1.0, 1.0, 0.75, 0.5, 0.25, 0.125,
         0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        365,
    ),
)
```

The defaults are workbook-free. The modes may be omitted when both sources use
`:arguments`:

```julia
options = Posy2Options(
    discountrate=0.05,
    co2_price=0.0,
)
```

## Workbook Paths

`data_dir` is the directory containing the input files. `techdata_file` and
`timeseries_file` are filenames relative to that directory. 

```julia
options = Posy2Options(
    data_dir="/path/to/scenario",
    techdata_file="technology_2050.xlsx",
    timeseries_file="timeseries_2050.xlsx",
    tech_mode=:excel,
    timeseries_mode=:excel,
)
```

In `:excel` mode, a builder keyword left as `nothing` is read from the
workbook. An explicit value replaces that lookup. Explicit profiles may be a
scalar that expands to every hour, or an hourly vector. 
See [Input Workbooks](input-data.md) for the full rules and sheet layout.

## Economic Assumptions

`discountrate` is used when builders annualise overnight investment and
decommissioning costs. [`eac`](@ref) combines the overnight cost, construction
profile, lifetime, and discount rate into an equivalent annual cost.
Construction profiles can be provided as one numeric value or as a vector of
yearly shares whose entries sum approximately to one.

In compact form, annualised investment is written as

```math
A^{\mathrm{inv}} = C_0 \, \phi^{\mathrm{build}} \, \mathrm{CRF}^*(r, L)
```

where ``C_0`` is the overnight cost, ``r`` is `discountrate`, ``L`` is
`lifetime`, and ``\phi^{\mathrm{build}}`` is the construction-profile
adjustment factor implied by `construction_profile`. The corrected annualisation
factor used by Posy2 is

```math
\mathrm{CRF}^*(r,L)
=
\frac{\mathrm{CRF}(r,L)}{1+r}
```

where ``\mathrm{CRF}(r,L)`` is the standard capital recovery factor:

```math
\mathrm{CRF}(r,L)
=
\begin{cases}
1/L, & r = 0 \\
\dfrac{r}{1-(1+r)^{-L}}, & r > 0
\end{cases}
```

The corresponding annualised decommissioning term is

```math
A^{\mathrm{decom}}
=
C_0 \, \delta \, (1+r)^{-L} \, \phi^{\mathrm{decom}} \, \mathrm{CRF}^*(r, L)
```

where ``\delta`` is the `decommissioning` ratio and
``\phi^{\mathrm{decom}}`` is the decommissioning-profile adjustment factor
implied by `decommissioning_profile`.

```julia
eac(
    4_000_000.0,             # overnight cost, currency per MW (4000 currency/kW)
    discountrate(snapshot),  # discount rate r, here the default 0.05
    60,                      # lifetime L, in years
    [0.3, 0.4, 0.3],         # construction profile: 30%, 40%, 30% over three years
)
# 222036.85956799964, i.e. about 222 000 currency per MW per year
```

Note the unit: builders take `overnight_cost` in currency per kW and multiply
it by 1000 before calling [`eac`](@ref), so a direct call takes currency per MW.
The returned annual cost is then in currency per MW per year.

The technology builders apply the resulting annual cost through Nosy fixed-cost
behaviours.

`co2_price` is the default carbon price passed to emitting generation
builders. When `co2_emission` is non-zero, the builder creates a linked CO2
output port, connects it to the supplied CO2 node, and applies the carbon price
to that flow. A builder-specific `co2price` keyword can override the study
default.

## Optional DC Power Flow

The `dcopf` flag controls whether [`applydcopf!`](@ref) adds Kirchhoff voltage
law constraints. Setting the flag does not add constraints by itself.

For a DC power flow study:

1. Set `dcopf=true` in `Posy2Options`.
2. Build electricity nodes with the `:electricity` tag.
3. Build AC node interconnections with [`makenodeinterco`](@ref),
   `dc=false`, and a negative series `susceptance` (``B\approx-1/X`` for
   inductive lines).
4. Build any controllable DC links with `dc=true`.
5. Call `applydcopf!(snapshot)` once, after all interconnections have been
   added and before optimisation.

With `dcopf=true` this order is enforced. `applydcopf!` builds the constraints
from the topology present at the call, so a second call and any later
[`makenodeinterco`](@ref) both raise an `ArgumentError` rather than leave the
model carrying stale KVL relations. Rebuilding the network means rebuilding the
snapshot.

```julia
options = Posy2Options(dcopf=true)
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

Posy2 constructs an undirected graph from AC node interconnections and adds
one KVL relation for each independent cycle. A tree has no cycle constraint.
Interconnections tagged as DC are excluded because their flow is controllable
and does not obey the AC cycle equations.

The susceptance registry is stored in `snapshot.options[:ic_susceptance]`.
This entry is managed by [`makenodeinterco`](@ref).

When `dcopf=false`, `applydcopf!` leaves the model unchanged. Call it after the
network is built in every study. Only the `dcopf` flag then chooses between
transport and DC power flow.