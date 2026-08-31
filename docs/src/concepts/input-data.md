# Input Workbooks

Posy2 can read scalar technology assumptions and hourly profiles from two
input workbooks, accept both kinds of input directly through builder keywords,
or mix those approaches. Technology values and time series are workbook-backed
defaults when their corresponding keyword is `nothing` and their input mode is
`:excel`.

The workbooks are ordinary `.xlsx` files read with XLSX.jl. They do not need
to contain every sheet described below. A study needs only the sheets,
technology columns, parameter rows, and time-series columns requested by the
builders it calls.

## Configuring Workbook Paths

Workbook locations belong in [`Posy2Options`](@ref), stored under the
snapshot's `:posy` option:

```julia
options = Posy2Options(
    data_dir=joinpath(@__DIR__, "data"),
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:excel,
    timeseries_mode=:excel,
    discount_rate=0.05,
    co2_price=0.0,
)

snapshot = Snapshot(sim, Dict(:posy => options))
```

By default, `data_dir` is `joinpath(pwd(), "data")` when `Posy2Options` is
created, and the workbook filenames are `"tech_data.xlsx"` and
`"time_series.xlsx"`. That path follows the process working directory, so the
same script can read different folders if you launch Julia from somewhere else.
Prefer an explicit `data_dir` anchored to the study, for example
`joinpath(@__DIR__, "data")`.

Workbooks are resolved lazily. Creating a snapshot does not open either file;
the first relevant builder lookup does. Reads are memoised using the file's
modification time, so editing a workbook invalidates the cached value.

Both modes default to `:arguments`, making their input sources workbook-free.
The two modes are independent. Explicit builder values take precedence in all
modes; an omitted value in `:arguments` mode uses the builder's documented
neutral default when one exists, while an omitted structural value raises
`ArgumentError` before file access.

See [Study Configuration](options.md) for the other study-wide options and the
[API Reference](../api.md) for the direct workbook-reader methods.

## General Layout And Lookup Rules

Sheet names, parameter names, and column headings are case-sensitive. Extra
columns, such as timestamps or comments, may be present. Posy2 only reads
the columns a builder looks up by name and ignores the rest.

Technology sheets use one row per parameter and one column per technology:

| `tech` | `CCGT` | `Nuclear` | `Onwind` |
|:-------|-------:|----------:|---------:|
| `overnight_cost` | `1000` | `6000` | `1200` |
| `lifetime` | `30` | `60` | `25` |
| `om_var_cost` | `2` | `3` | `0` |

The first column must be named exactly `tech` and lists parameter names.
The `tech_column` keyword passed to a builder selects a technology column and
normally defaults to `tech`. For example, `tech_column="CCGT"` and
`param="overnight_cost"` select the value at row `overnight_cost`, column
`CCGT`.

Time-series sheets use one column per lookup key. A builder requests the
complete column and expects it to align with the simulation mesh. Posy2
rejects missing or `NaN` entries, but the reader itself does not validate the
series length, units, or physical bounds.

Missing files fail when they are opened. Missing sheets, columns, parameter
rows, blank technology cells, and missing time-series values raise an
`ArgumentError` with workbook context.

## Keyword Overrides

The costed builders expose workbook-backed values as keywords. The lookup rule
is consistent:

```julia
makedispatchable(
    "Gas",
    electricity,
    snapshot;
    co2_node=co2, tech_column="CCGT",
    fuel_cost=nothing,  # read dispatchable/CCGT/fuel_cost
)
```

Passing a value replaces that one lookup:

```julia
makedispatchable(
    "Gas sensitivity",
    electricity,
    snapshot;
    co2_node=co2, tech_column="CCGT",
    fuel_cost=40.0,
)
```

Passing a keyword overrides that lookup for this builder call only. It does not
edit the workbook, and [`gettechparam`](@ref) still returns the workbook value.
If every technology keyword is supplied, that component does not read the
technology workbook. With `tech_mode=:arguments`, any omitted technology
keyword raises `ArgumentError` instead of falling back to workbook.

Time-series builders use the same rule. Explicit series accept either a real
number, expanded to all hours, or a vector with exactly
`Nosy.nhours(sim(snapshot))` finite numeric values. The direct keywords are:

| Builder | Direct Keyword | Workbook Fallback |
|:--------|:---------------|:---------------|
| [`makedemand`](@ref) | `profile` | `<zone>` in `demand` |
| [`makeintermittentsource`](@ref) | `profile` | `<tech_column>_<node>` in `profiles_<year>` |
| [`makehydroror`](@ref) | `intake_profile` | `<zone>` in `hydro_ror_<year>` |
| [`makehydroreservoir`](@ref) | `intake_profile` | `<zone>` in `reservoir_inflow_<year>` |
| [`makeEV`](@ref) | `departures` | `<zone>` in `EV_departure` |
| [`makeEV`](@ref) | `arrivals` | `<zone>` in `EV_arrival` |
| [`makeEV`](@ref) | `departure_soc` | `<zone>` in `EV_departure_soc` |
| [`makeEV`](@ref) | `arrival_soc` | `<zone>` in `EV_arrival_soc` |
| [`makepricelink`](@ref) | `spot_price` | `<neighbor_column>` in `spot_price` |
| [`makepricelink`](@ref) | `import_availability` | `<neighbor_column>>local` in `transfer_capacities` |
| [`makepricelink`](@ref) | `export_availability` | `local><neighbor_column>` in `transfer_capacities` |
| [`maketransmissionlink`](@ref) | `a_to_b_availability` | `a>b` in `transfer_capacities_AC` (`dc=false`) or `transfer_capacities_DC` (`dc=true`) |
| [`maketransmissionlink`](@ref) | `b_to_a_availability` | `b>a` in `transfer_capacities_AC` (`dc=false`) or `transfer_capacities_DC` (`dc=true`) |

For example, this demand never reads `time_series.xlsx`:

```julia
# Flat 100 MW for every hour of the mesh.
hourly_demand = 100.0

makedemand(
    "Demand", "country1", electricity, snapshot;
    profile=hourly_demand,
)
```

## Construction And Decommissioning Profiles

`construction_profile` and `decommissioning_profile` accept either a number
or a vector of yearly shares. Values are non-negative chronological cost
shares and must sum approximately to one:

```julia
construction_profile = [0.3, 0.4, 0.3]
decommissioning_profile = 1.0
```

Workbook cells hold the same shares as a semicolon-separated string such as
`"0.3;0.4;0.3"`; `gettechparam` turns them into a vector when the sheet is
read.

A single number means the whole cost falls in one year, so that number must be
about `1.0`. Shares that sum only approximately to one are renormalised after
the check. Annualised builders need both profiles unless you pass them as
keywords.

## Technology Workbook

Posy2 uses four technology sheets:

| Sheet | Modelling role |
|:------|:---------------|
| `dispatchable` | Dispatchable and nuclear generation |
| `intermittent` | Wind, solar, and run-of-river generation |
| `storage` | Reservoirs, batteries, hydrogen storage, and EV fleets |
| `electrolysis` | Electrolysers |

Unless a note says otherwise, each listed row name is also the builder keyword
of the same name.

### Dispatchable Sheet

Both [`makedispatchable`](@ref) and [`makenuclear`](@ref) always read these
rows when the matching keyword is `nothing`:
`overnight_cost`, `lifetime`, `construction_profile`,
`decommissioning_profile`, `connection_cost`, `om_fixed_cost`,
`om_var_cost`, `decommissioning`, `co2_emission`, and `unit_size`.

| Builder | Base Rows | Conditional Groups |
|:--------|:----------|:-------------------|
| [`makedispatchable`](@ref) | Common | Fuel, unit commitment, and ramping |
| [`makenuclear`](@ref) | Common plus `waste_cost` | Fuel, unit commitment, ramping, and refuelling |

In `:arguments` mode, `makedispatchable` gives its additive cost and emission
coefficients neutral zero defaults. It uses `nothing` for unit sizing and
ramping, and a lossless efficiency of one when a fuel node is supplied. In
`:excel` mode, use `unit_size=0` to override the workbook with no unit sizing.
`lifetime` and `construction_profile` are required only for non-zero overnight
cost; `decommissioning_profile` is required only when overnight cost and the
decommissioning ratio are both non-zero. These defaults currently apply only
to `makedispatchable`, not `makenuclear`.

For the fuel group, `makedispatchable` and `makenuclear` read `fuel_cost`
without `fuel_node`, or `efficiency` with `fuel_node`.

For `makedispatchable` and `makenuclear`, enabling unit commitment reads
`no_load_cost` and `startup_cost`. Only `uc=true` also reads `min_power`,
`min_uptime`, `min_downtime`, `startup_duration`, and `shutdown_duration`:
`uc=<extracted snapshot>` replays a solved commitment schedule and needs none
of them.

With the default `refuel=true`, `uc=true` on nuclear additionally reads
`refuel_fraction_per_year`, and a positive refuel fraction causes
`refuel_duration` to be read. Set `refuel=false` to skip these reads and disable
refuelling. `refuel_slot_spacing` is an argument-only `Integer` spacing, in hours, of
allowed outage starts and has no
workbook row. A replayed schedule already contains whatever refuelling outages
it was solved with, so `uc=<extracted snapshot>` builds no refuelling constraints
and warns if refuelling arguments are supplied.

`ramp_up` and `ramp_down` are used by `makedispatchable` and `makenuclear` only
when `unit_size > 0`. In `:arguments` mode, omitted, `nothing`, or zero ramp
values omit the corresponding constraint. In `:excel` mode, omitted or
`nothing` values are read from the technology column. Unit commitment and
non-zero fractional ramps require a positive unit size.

### Intermittent Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makeintermittentsource`](@ref) | Intermittent-source rows |
| [`makehydroror`](@ref) | Run-of-river rows |

Intermittent-source rows are `overnight_cost`, `lifetime`,
`construction_profile`, `decommissioning_profile`, `connection_cost`,
`om_fixed_cost`, `om_var_cost`, `fuel_cost`, `decommissioning`, and
`co2_emission`.

Run-of-river rows are `overnight_cost`, `lifetime`, `construction_profile`,
`decommissioning_profile`, `om_fixed_cost`, `om_var_cost`, and
`decommissioning`.

`makehydroror` defaults to `tech_column="Hydro ror"`. Pass another `tech_column` to
read a different column on the `intermittent` sheet.

### Storage Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makehydroreservoir`](@ref) | Reservoir rows |
| [`makebatterystorage`](@ref) | Battery rows |
| [`makehydrogenstorage`](@ref) | Hydrogen-storage rows |
| [`makeEV`](@ref), smart or V2G | EV-fleet rows |

Reservoir rows are `roundtrip_eff`, `overnight_cost`, `lifetime`,
`construction_profile`, `decommissioning_profile`, `om_fixed_cost`,
`om_var_cost`, and `decommissioning`.

Battery rows add `duration` and `connection_cost` to the reservoir rows.
Hydrogen-storage rows are `roundtrip_eff`, `overnight_cost`, `lifetime`,
`construction_profile`, `decommissioning_profile`, `om_fixed_cost`, and
`decommissioning`.

EV-fleet rows are `charging_eff`, `self_discharge`,
`max_charging_power`, `max_dispatch_power`, and `battery_capacity`.

In smart-charging or V2G mode, [`makeEV`](@ref) defaults to technology column
`EV`, but its `tech_column` keyword can select another column.

The `roundtrip_eff` row maps to the builder keyword of the same name. EV rows ending in
power or capacity map to the corresponding `*_per_ev` override keywords.
Fixed-profile EV mode reads no technology data.

### Electrolysis Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makeelectrolyser`](@ref) | Electrolysis rows |

Electrolysis rows are `efficiency`, `overnight_cost`, `lifetime`,
`construction_profile`, `decommissioning_profile`, `decommissioning`,
`om_fixed_cost`, and `om_var_cost`.

The `efficiency` row maps to the keyword of the same name.

## Parameter Conventions And Validation

Example studies use MW, MWh, and a currency. Under that convention the builders
scale workbook values as follows:

| Parameter | Builder Treatment |
|:----------|:------------------|
| `overnight_cost` | Multiplied by 1000, then annualised (enter currency per kW) |
| `om_fixed_cost` | Multiplied by 1000 (enter currency per kW per year) |
| `om_var_cost`, `fuel_cost`, `waste_cost` | Per unit of the priced energy flow |
| `connection_cost` | Fraction of annualised investment |
| `decommissioning` | Fraction of overnight cost |
| `lifetime` | Positive integer years |
| `efficiency`, `roundtrip_eff`, `charging_eff` | Fraction in `(0, 1]` |
| `co2_emission` | Divided by 1000 (enter kgCO2/MWh if CO2 is in tonnes) |
| `unit_size` | `0` means no unit size; otherwise must be positive |
| `duration` | Positive storage duration |

These conversions always apply. If you enter values already in per-MW or
tCO2 units, or change the study’s power or CO2 units, scale the inputs
yourself so the applied values stay correct.

### Example technology assumptions

The values in `data/tech_data.xlsx` are illustrative values selected to support 
the documentation examples. They are not recommended technology assumptions or 
a ready-made dataset for other studies.

The example costs are based on the IEA/NEA report
[*Projected Costs of Generating Electricity 2020*](https://www.iea.org/reports/projected-costs-of-generating-electricity-2020)
and its supporting data tables. 
For each report-based technology x parameter, the median value across countries
was selected. The hydrogen-storage values are the illustrative assumptions used
by the hydrogen-production example.

| Workbook key | Example assumption or report technology |
|:-------------|:----------------------------------------|
| `PV` | Utility-scale solar PV |
| `Onwind` | Onshore wind, at least 1 MW |
| `CCGT` | Combined-cycle gas turbine |
| `OCGT` | Open-cycle gas turbine |
| `Nuclear` | New-build nuclear |
| `Battery` | Four-hour lithium-ion battery observation |
| `Hydro res` | Reservoir hydro, at least 5 MW |
| `Hydro ror` | Run-of-river hydro, at least 5 MW |
| `Hydrogen storage` | Illustrative hydrogen storage: 100% roundtrip efficiency, 30-year lifetime |
| `PEM` | Current PEM electrolyser |

## Time-Series Workbook

The time-series lookup key depends on the builder:

Weather-indexed builders require an explicit `weather_year` when they read a
workbook. The keyword is unused when the corresponding profile is supplied
directly.

| Sheet | Expected Column | Used By And Condition |
|:------|:----------------|:----------------------|
| `demand` | `<zone>` | [`makedemand`](@ref) when `profile_multiplier != 0` |
| `profiles_<year>` | `<tech_column>_<node-name>` | [`makeintermittentsource`](@ref) |
| `hydro_ror_<year>` | `<zone>` | [`makehydroror`](@ref) |
| `reservoir_inflow_<year>` | `<zone>` | [`makehydroreservoir`](@ref) when intake is enabled (`intake != 0`) |
| `EV_departure` | `<zone>` | [`makeEV`](@ref) in smart-charging or V2G mode |
| `EV_arrival` | `<zone>` | [`makeEV`](@ref) in smart-charging or V2G mode |
| `EV_departure_soc` | `<zone>` | [`makeEV`](@ref) in smart-charging or V2G mode |
| `EV_arrival_soc` | `<zone>` | [`makeEV`](@ref) in smart-charging or V2G mode |
| `spot_price` | `<neighbor_column>` | [`makepricelink`](@ref), unless both capacities are a fixed zero |
| `transfer_capacities` | `From>To` | [`makepricelink`](@ref), per direction that is not a fixed zero |
| `transfer_capacities_AC` | `From>To` | [`maketransmissionlink`](@ref) with `dc=false`, when shared `cap` is not a fixed zero |
| `transfer_capacities_DC` | `From>To` | [`maketransmissionlink`](@ref) with `dc=true`, when shared `cap` is not a fixed zero |

For example, technology `Onwind` connected to electricity node `country1` in
weather year 2019 requests column `Onwind_country1` from sheet `profiles_2019`.
Transfer columns use a single `>` with no spaces: a country1-to-country2
direction is `country1>country2`.

The principal series semantics are:

- `demand` contains exogenous hourly demand. `profile_multiplier` multiplies it, `profile_shift_hours`
  circularly shifts it, and `annual_flat_demand / 8760` is then added.
- `profiles_<year>` contains a profile that multiplies installed capacity.
- `hydro_ror_<year>` contains an intake shape. The builder normalises it to sum
  to one, distributes `intake` over that shape, and limits hourly
  output by the fixed or optimised output capacity.
- `reservoir_inflow_<year>` contains a natural-intake shape. As for run-of-river,
  the builder normalises it to sum to one and scales it by `intake`.
  `intake=0` disables natural intake without reading a
  profile; otherwise workbook lookup requires an explicit `weather_year` when
  `intake_profile` is omitted.
- `EV_departure` and `EV_arrival` hold hourly vehicle counts (nonnegative).
  `EV_departure_soc` and `EV_arrival_soc` hold mean state-of-charge values in
  `[0, 1]`. The builder converts these inputs to fixed `departure` and `arrival`
  energy flows using `battery_capacity_per_ev`, tracks the connected fleet, and
  applies `n_t / number_ev` as the charging availability multiplier. Annual
  departure and arrival counts must balance on a circular mesh.
- The three `transfer_capacities*` sheets all hold hourly availability
  multipliers per direction (`From>To`), and differ only in which builder reads
  them. Each interconnection kind owns one sheet, so an AC and a DC link on the
  same node pair, or a priced corridor sharing a zone name with a modelled node,
  keep separate series:
  - `transfer_capacities` for [`makepricelink`](@ref);
  - `transfer_capacities_AC` for [`maketransmissionlink`](@ref) with `dc=false`;
  - `transfer_capacities_DC` for [`maketransmissionlink`](@ref) with `dc=true`.
- For [`maketransmissionlink`](@ref), the shared `cap` is multiplied by column `a>b`
  for forward ATC and by `b>a` for reverse ATC. A fixed zero `cap` reads neither
  column.
- [`makepricelink`](@ref) uses both directional transfer series and the
  neighbour spot price, all named after `neighbor_column`. Each can be supplied
  explicitly or read from its workbook fallback. A direction fixed at zero reads
  no transfer column, and two zero capacities also skip the spot price.

Physical domains are enforced when a series is resolved, whether it comes from
the workbook or from a keyword. Availability and capacity multipliers
(`profiles_<year>`, the `transfer_capacities*` sheets) must lie
in `[0, 1]`; intake shapes (`hydro_ror_<year>`, `reservoir_inflow_<year>`) must
be nonnegative and sum to a strictly positive value; `EV_departure` and
`EV_arrival` must be nonnegative; `EV_departure_soc` and `EV_arrival_soc` must
lie in `[0, 1]`. `demand` and `spot_price` are unrestricted
beyond being numeric and finite.

## Full-year Hourly Requirement

Every builder requires a snapshot spanning a non-leap year of 8,760 hours and
rejects any other horizon: flat annual demands divide by 8,760, fixed-profile
EVs construct 8,760 entries, nuclear refuelling places its outage starts on an
hour grid spanning the year, and the standard report labels 8,760 time rows.

Workbook columns therefore carry 8,760 values, one per hour, matching Nosy's
default [`TimeMesh`](https://oecd-nea.github.io/Nosy.jl/dev/concepts/time/).
Only the number of hours is constrained, so a mesh that aggregates steps is
still accepted, and a workbook column stays on the hour grid either way. Such a
mesh samples the column rather than averaging it, which changes the annual total
of every non-flat series.

!!! note
    The workbooks in `data` are neutral documentation inputs, not calibrated
    scenario projections. Technology CAPEX, lifetime, construction, and
    decommissioning assumptions are based on the IEA/NEA report *Projected
    Costs of Generating Electricity 2020 Edition*. All documentation
    time-series values and geographic labels are synthetic and reproducibly
    generated. `tech_data.xlsx` contains only the technology keys used by the
    documentation examples (including the implicit `EV` key). The smaller
    files in `test/data` remain contract fixtures for automated tests.

## Inspecting Workbook Values

Use the direct readers when you need to check what a workbook actually
contains—for example after an unexpected cost or a missing time-series column.
Both calls return the same workbook values.

When no snapshot is available, open the file and query the handle:

```julia
techbook = readtechdata("tech_data.xlsx"; data_dir=options.data_dir)
gettechparam(techbook, "CCGT", "fuel_cost", "dispatchable", 6)

seriesbook = readtimeseries(
    "time_series.xlsx";
    data_dir=options.data_dir,
)
gettimeseries(seriesbook, "country1", "demand", 6)
```

While building a study, pass the snapshot so Posy2 opens the configured
workbooks for you:

```julia
gettechparam(snapshot, "CCGT", "fuel_cost", "dispatchable"; digits=6)
gettimeseries(snapshot, "country1", "demand"; digits=6)
```

These snapshot calls require `tech_mode=:excel` and
`timeseries_mode=:excel` respectively. In `:arguments` mode, open the
workbook handle instead.
