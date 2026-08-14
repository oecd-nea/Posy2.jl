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
    discountrate=0.05,
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

Set `tech_mode=:arguments` or `timeseries_mode=:arguments` to make an input
source strict and workbook-free. The two modes are independent. Explicit
builder values take precedence in all modes; a missing value in `:arguments`
mode raises `ArgumentError` before file access.

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
The `techkey` argument passed to a builder selects a technology column. 
For example, `techkey="CCGT"` and `param="overnight_cost"` select 
the value at row `overnight_cost`, column `CCGT`.

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
    "CCGT",
    electricity,
    co2,
    snapshot;
    fuel_cost=nothing,  # read dispatchable/CCGT/fuel_cost
)
```

Passing a value replaces that one lookup:

```julia
makedispatchable(
    "Gas sensitivity",
    "CCGT",
    electricity,
    co2,
    snapshot;
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
| [`makeintermittentsource`](@ref) | `profile` | `<techkey>_<node>` in `profiles_<year>` |
| [`makehydroror`](@ref) | `inflow_profile` | `<zone>` in `hydro_ror_<year>` |
| [`makehydroreservoir`](@ref) | `inflow_profile` | `<zone>` in `reservoir_inflow_<year>` |
| [`makeEV`](@ref) | `charging_availability` | `<zone>` in `EV_charging_availability` |
| [`makeEV`](@ref) | `driving_profile` | `<zone>` in `EV_driving_profile` |
| [`makepriceinterco`](@ref) | `spot_price` | `<foreign-zone>` in `spot_price` |
| [`makepriceinterco`](@ref) | `import_availability` | `zone>local` in `transfer_capacities` |
| [`makepriceinterco`](@ref) | `export_availability` | `local>zone` in `transfer_capacities` |
| [`makenodeinterco`](@ref) | `atob_availability` | `a>b` in `transfer_capacities` |
| [`makenodeinterco`](@ref) | `btoa_availability` | `b>a` in `transfer_capacities` |

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
or a semicolon-separated string. Values are non-negative chronological cost
shares and must sum approximately to one:

```julia
construction_profile = "0.3;0.4;0.3"
decommissioning_profile = 1.0
```

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
| [`makenuclear`](@ref) | Common plus `waste_cost` | Fuel, unit commitment, and reloads |

For the fuel group, `makedispatchable` and `makenuclear` read `fuel_cost`
without `fuelnode`, or `efficiency` with `fuelnode`.

For `makedispatchable` and `makenuclear`, `uc=true` reads `no_load_cost` and
`startup_cost`. When no initial snapshot supplies unit-commitment behaviour,
it also reads `min_power`, `min_uptime`, `min_downtime`,
`startup_duration`, and `shutdown_duration`.

Nuclear unit commitment additionally reads `reload_fraction_per_year`. A
positive reload fraction causes `reload_duration` to be read. `reloadmask` is
an argument-only scheduling interval and has no workbook row.

`ramp_up` and `ramp_down` are used by `makedispatchable` only when
`unit_size > 0`; zero ramp values omit the corresponding constraint.

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

`makehydroror` defaults to `techkey="Hydro ror"`. Pass another `techkey` to
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

EV-fleet rows are `charging_eff`, `self_discharge`, `min_level_morning`,
`max_charging_power`, `max_dispatch_power`, `battery_capacity`, and
`yearly_consumption`.

In smart-charging or V2G mode, [`makeEV`](@ref) defaults to technology column
`EV`, but its `techkey` keyword can select another column.

The `roundtrip_eff` row maps to the builder keyword `eff`. EV rows ending in
power, capacity, or consumption map to the corresponding `*_per_ev` override
keywords. Fixed-profile EV mode reads no technology data.

### Electrolysis Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makeelectrolyser`](@ref) | Electrolysis rows |

Electrolysis rows are `efficiency`, `overnight_cost`, `lifetime`,
`construction_profile`, `decommissioning_profile`, `decommissioning`,
`om_fixed_cost`, and `om_var_cost`.

The `efficiency` row maps to the keyword `eff`.

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

Shared checks: `0 <= gridlosses < 1`. Demand coefficients and annual demand
must be non-negative. EV bounds are in [`makeEV`](@ref). Costs must be numeric
but may be negative.

## Time-Series Workbook

The time-series lookup key depends on the builder:

| Sheet | Expected Column | Used By And Condition |
|:------|:----------------|:----------------------|
| `demand` | `<zone>` | [`makedemand`](@ref) when `coeff != 0` |
| `profiles_<year>` | `<techkey>_<node-name>` | [`makeintermittentsource`](@ref) |
| `hydro_ror_<year>` | `<zone>` | [`makehydroror`](@ref) |
| `reservoir_inflow_<year>` | `<zone>` | [`makehydroreservoir`](@ref) when inflow is enabled (`inflow != 0`) |
| `EV_charging_availability` | `<zone>` | [`makeEV`](@ref) in smart-charging or V2G mode |
| `EV_driving_profile` | `<zone>` | [`makeEV`](@ref) in smart-charging or V2G mode |
| `spot_price` | `<foreign-zone>` | [`makepriceinterco`](@ref) |
| `transfer_capacities` | `From>To` | Price IC always; node IC when that direction's capacity is finite |

For example, technology `Onwind` connected to electricity node `country1` in
weather year 2019 requests column `Onwind_country1` from sheet `profiles_2019`.
Transfer columns use a single `>` with no spaces: a country1-to-country2
direction is `country1>country2`.

The principal series semantics are:

- `demand` contains exogenous hourly demand. `coeff` multiplies it, `shift`
  circularly shifts it, and `yearlyconstant / 8760` is then added.
- `profiles_<year>` contains a profile that multiplies installed capacity.
- `hydro_ror_<year>` contains absolute inflow. The builder divides it by the
  required fixed capacity, applies `intake_mult`, and cuts capacity factors
  above one (`cutoff=1`).
- `reservoir_inflow_<year>` is natural inflow. `inflow=nothing` uses the raw
  profile times `intake_mult`. `inflow=0` turns inflow off (no sheet read;
  `inflow_profile` is ignored too). A non-zero `inflow` scales the profile
  and always applies `intake_mult`. `renormalize=true` first normalises the
  profile to sum to one, but only for a non-zero numeric `inflow`; it is
  ignored when `inflow=nothing`.
- EV charging availability is a capacity multiplier. The driving profile is
  normalised to the requested annual EV consumption and must have a positive
  sum.
- `transfer_capacities` holds hourly availability multipliers per direction
  (`From>To`). For [`makenodeinterco`](@ref), a finite `atob` reads column
  `a>b` and a finite `btoa` reads `b>a`. An `Inf` direction has no capacity
  limit, so that column is not read.
- [`makepriceinterco`](@ref) uses both directional transfer series and the
  foreign-zone spot price. Each can be supplied explicitly or read from its
  workbook fallback.

Posy2 does not require `profiles_<year>` or `transfer_capacities` values to
lie in a fixed range (such as 0–1) when they are read. Validate such data
before a production run.

## Full-year Hourly Assumption

Nosy supports custom and heterogeneous meshes, but several Posy2 builders and
reports currently assume a non-leap year of 8,760 hourly values. Flat annual
demands divide by 8,760, fixed-profile EVs construct 8,760 entries, nuclear
reload logic iterates over 8,760 hours, and the standard report labels 8,760 time
rows.

Use 8,760-value workbook columns with Nosy's default
[`TimeMesh`](https://oecd-nea.github.io/Nosy.jl/dev/concepts/time/) for the
documented full-year workflow. A different mesh may work for an individual
builder that has no hard-coded annual logic, but it is not supported uniformly
across Posy2.

!!! note
    The workbooks in `data` are neutral documentation inputs, not calibrated
    scenario projections. Technology CAPEX, lifetime, construction, and
    decommissioning assumptions are based on the IEA/NEA report *Projected
    Costs of Generating Electricity 2020 Edition*. All documentation
    time-series values and geographic labels are synthetic and reproducibly
    generated. The smaller files in `test/data` remain contract fixtures for
    automated tests.

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