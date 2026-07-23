# Input Workbooks

POSY2 can read scalar technology assumptions and hourly profiles from two
Excel workbooks, accept both kinds of input directly through builder keywords,
or mix those approaches. Technology values and time series are Excel-backed
defaults when their corresponding keyword is `nothing` and their input mode is
`:excel`.

The workbooks are ordinary `.xlsx` files read with XLSX.jl. They do not need
to contain every sheet described below. A study needs only the sheets,
technology columns, parameter rows, and time-series columns requested by the
builders it calls.

## Configuring Workbook Paths

Workbook locations belong in [`POSY2Options`](@ref), stored under the
snapshot's `:posy` option:

```julia
options = POSY2Options(
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

`data_dir` defaults to `joinpath(pwd(), "data")` at the time the options
object is created. `techdata_file` and `timeseries_file` default to
`"tech_data.xlsx"` and `"time_series.xlsx"`. An explicit `data_dir`, based on
`@__DIR__` or another stable scenario path, avoids making results depend on
the process working directory.

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
columns, such as timestamps or comments, are allowed and ignored unless a
builder requests them.

Technology sheets use one row per parameter and one column per technology:

| `tech` | `CCGT` | `Nuclear` | `Onwind` |
|:-------|-------:|----------:|---------:|
| `overnight_cost` | `1000` | `6000` | `1200` |
| `lifetime` | `30` | `60` | `25` |
| `om_var_cost` | `2` | `3` | `0` |

The first column must be named exactly `tech`. Despite that heading, its cells
are **parameter names**. The `tech` argument passed to a builder selects a
technology **column**. For example, `tech="CCGT"` and
`param="overnight_cost"` select the value at row `overnight_cost`, column
`CCGT`.

Time-series sheets use one column per lookup key. A builder requests the
complete column and expects it to align with the simulation mesh. POSY2
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

An explicit override does not modify the workbook or the value returned by
[`gettechparam`](@ref). Supplying every technology keyword removes all
technology-workbook reads for that component. Selecting
`tech_mode=:arguments` additionally detects any accidentally omitted value.

Time-series builders use the same rule. Explicit series accept either a real
number, expanded to all hours, or a vector with exactly
`Nosy.nhours(sim(snapshot))` finite numeric values. The direct keywords are:

| Builder | Direct Keyword | Excel Fallback |
|:--------|:---------------|:---------------|
| [`makedemand`](@ref) | `profile` | `<zone>` in `demand` |
| [`makeintermittentsource`](@ref) | `profile` | `<tech>_<node>` in `profiles_<year>` |
| `POSY2.makenuclearprofile` | `profile` | `<tech>_<node>` in `profiles_<year>` |
| [`makehydroror`](@ref) | `inflow_profile` | `<zone>` in `hydro_ror_<year>` |
| [`makehydroreservoir`](@ref) | `inflow_profile` | `<zone>` in `reservoir_inflow_<year>` |
| `POSY2.makereservoirprofile` | `output_profile` | `<zone>` in `fixed_reservoir_output` |
| [`makeEV`](@ref) | `charging_availability`, `driving_profile` | `<zone>` in the two EV sheets |
| [`makepriceinterco`](@ref) | `spot_price`, `import_availability`, `export_availability` | Price and directional-transfer columns |
| [`makenodeinterco`](@ref) | `atob_availability`, `btoa_availability` | Directional-transfer columns |

For example, this demand never reads `time_series.xlsx`:

```julia
makedemand(
    "Demand", "unused", electricity, snapshot;
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

A scalar represents a one-period profile, so the only valid scalar share is
approximately `1.0`. POSY2 normalises small rounding differences after
checking the sum. These two rows are needed by every annualised builder unless
they are overridden.

## Technology Workbook

POSY2 uses four technology sheets:

| Sheet | Modelling role |
|:------|:---------------|
| `dispatchable` | Dispatchable, nuclear, and SMR generation |
| `intermittent` | Wind, solar, and run-of-river generation |
| `storage` | Reservoirs, batteries, hydrogen storage, and EV fleets |
| `electrolysis` | Low- and high-temperature electrolysers |

Every row listed in the tables below has a same-named builder keyword unless
the notes say otherwise. A row is read only when that keyword remains
`nothing` and the stated operating mode uses it.

### Dispatchable Sheet

The common dispatchable rows are:

- `overnight_cost`, `lifetime`, `construction_profile`, and
  `decommissioning_profile`;
- `connection_cost`, `om_fixed_cost`, `om_var_cost`, and
  `decommissioning`;
- `co2_emission` and `unit_size`.

| Builder | Base Rows | Conditional Groups |
|:--------|:----------|:-------------------|
| [`makedispatchable`](@ref) | Common | Fuel, unit commitment, and ramping |
| [`makenuclear`](@ref) | Common plus `waste_cost` | Fuel, unit commitment, and reloads |
| [`makesmr`](@ref) | Common plus `fuel_cost` and `waste_cost` | None |
| `POSY2.makenuclearprofile` | Common without `connection_cost` and `unit_size`; always includes `fuel_cost` | None |

For the fuel group, `makedispatchable` and `makenuclear` read `fuel_cost`
without `fuelnode`, or `efficiency` with `fuelnode`. `makesmr` always reads
`fuel_cost`; it has no fuel-node efficiency mode. `POSY2.makenuclearprofile`
always reads `fuel_cost` and has no fuel-node efficiency mode.

For `makedispatchable` and `makenuclear`, `uc=true` reads `no_load_cost` and
`startup_cost`. When no initial snapshot supplies unit-commitment behaviour,
it also reads `min_power`, `min_uptime`, `min_downtime`,
`startup_duration`, and `shutdown_duration`.

Nuclear unit commitment additionally reads `reload_fraction_per_year`. A
positive reload fraction causes `reload_duration` to be read. `reloadmask` is
an argument-only scheduling interval and has no workbook row.

`ramp_up` and `ramp_down` are used by `makedispatchable` only when
`unit_size > 0`; zero ramp values omit the corresponding constraint.

The `POSY2.makenuclearprofile` reads `overnight_cost`,
`lifetime`, both profiles, `om_fixed_cost`, `om_var_cost`, `fuel_cost`,
`decommissioning`, and `co2_emission`.

### Intermittent Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makeintermittentsource`](@ref) | Intermittent-source rows |
| [`makehydroror`](@ref) | Run-of-river rows |

Intermittent-source rows are `overnight_cost`, `lifetime`,
`construction_profile`, `decommissioning_profile`, `connection_cost`,
`om_fixed_cost`, `om_var_cost`, `fuel_cost`, `decommissioning`, and
`co2_emission`.

Run-of-river rows are `overnight_cost`, `lifetime`, both profiles,
`om_fixed_cost`, `om_var_cost`, and `decommissioning`.

`makehydroror` defaults to technology column `Hydro ror`, but its `tech`
keyword can select another column.

### Storage Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makehydroreservoir`](@ref) | Reservoir rows |
| [`makebatteries`](@ref) | Battery rows |
| [`makehydrogenstorage`](@ref) | Hydrogen-storage rows |
| [`makeEV`](@ref), smart or V2G | EV-fleet rows |
| `POSY2.makereservoirprofile` | Reservoir-profile rows |

Reservoir rows are `roundtrip_eff`, `overnight_cost`, `lifetime`, both
profiles, `om_fixed_cost`, `om_var_cost`, and `decommissioning`.

Battery rows add `duration` and `connection_cost` to the reservoir rows.
Hydrogen-storage rows are `roundtrip_eff`, `overnight_cost`, `lifetime`, both
profiles, `om_fixed_cost`, and `decommissioning`.

EV-fleet rows are `charging_eff`, `self_discharge`, `min_level_morning`,
`max_charging_power`, `max_dispatch_power`, `battery_capacity`, and
`yearly_consumption`.

Reservoir-profile rows are `overnight_cost`, `lifetime`, both profiles,
`om_fixed_cost`, `om_var_cost`, and `decommissioning`.

`POSY2.makereservoirprofile` defaults to technology column `Hydro res`, but
its `tech` keyword can select another column.

In smart-charging or V2G mode, [`makeEV`](@ref) defaults to technology column
`EV`, but its `tech` keyword can select another column.

The `roundtrip_eff` row maps to the builder keyword `eff`. EV rows ending in
power, capacity, or consumption map to the corresponding `*_per_ev` override
keywords. Fixed-profile EV mode reads no technology data.

### Electrolysis Sheet

| Builder | Parameter Set |
|:--------|:--------------|
| [`makeelectrolyser`](@ref) | Electrolysis rows |
| [`makeHTelectrolyser`](@ref) | Electrolysis rows |

Electrolysis rows are `efficiency`, `overnight_cost`, `lifetime`, both
profiles, `decommissioning`, `om_fixed_cost`, and `om_var_cost`.

The `efficiency` row maps to the keyword `eff`.

## Parameter Conventions And Validation

With the MW, MWh, and currency convention used by the examples, the workbook
parameters have the following interpretation:

| Parameter | Builder Treatment |
|:----------|:------------------|
| `overnight_cost` | Multiplied by 1,000 before annualisation; conventionally currency/kW |
| `om_fixed_cost` | Multiplied by 1,000; conventionally currency/kW/year |
| `om_var_cost`, `fuel_cost`, `waste_cost` | Applied directly per unit of the relevant energy flow |
| `connection_cost` | Ratio applied to annualised investment cost |
| `decommissioning` | Total decommissioning cost as a ratio of overnight cost |
| `lifetime` | Positive, integer-valued operating life |
| `efficiency`, `roundtrip_eff`, `charging_eff` | Fraction in `(0, 1]` |
| `co2_emission` | Divided by 1,000 to create the CO2 flow; with MWh and tonnes, supply kgCO2/MWh |
| `unit_size` | Zero disables unit sizing; a non-zero value must be positive |
| `duration` | Positive storage duration used by the Nosy duration behaviour |

The model remains unit-agnostic only when these built-in factors are included
in the chosen convention.

Shared validation also requires `0 <= gridlosses < 1`. Demand coefficients and
annual demand values must be non-negative. EV efficiency, self-discharge,
morning level, power, battery, and yearly-consumption inputs have the bounds
documented in the [`makeEV`](@ref) API entry. Costs are checked for numeric
type but are not generally constrained to be non-negative.

## Time-Series Workbook

The time-series lookup key depends on the builder:

| Sheet | Expected Column | Used By And Condition |
|:------|:----------------|:----------------------|
| `demand` | `<zone>` | [`makedemand`](@ref) when `coeff != 0` |
| `profiles_<year>` | `<tech>_<node-name>` | Intermittent and internal nuclear profile |
| `hydro_ror_<year>` | `<zone>` | [`makehydroror`](@ref) |
| `reservoir_inflow_<year>` | `<zone>` | [`makehydroreservoir`](@ref) when inflow is enabled (`inflow != 0`) |
| `fixed_reservoir_output` | `<zone>` | `POSY2.makereservoirprofile` (absolute output; divided by `cap`) |
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
- `reservoir_inflow_<year>` contains natural inflow. `inflow=nothing` uses the
  raw profile multiplied by `intake_mult`; `inflow=0` disables inflow entirely
  (no sheet read; an explicit `inflow_profile` is also ignored); and a
  non-zero numeric `inflow` scales the profile and always applies
  `intake_mult`. With `renormalize=true`, POSY2 first normalises the profile to
  sum to one before that scaling, but only when `inflow` is a non-zero number;
  `renormalize` is ignored when `inflow=nothing`.
- `fixed_reservoir_output` contains absolute hourly output. The
  `POSY2.makereservoirprofile` divides it by `cap` to form a capacity factor.
- EV charging availability is a capacity multiplier. The driving profile is
  normalised to the requested annual EV consumption and must have a positive
  sum.
- `transfer_capacities` contains directional availability multipliers. For
  [`makenodeinterco`](@ref), a finite `atob` reads `a>b` and a finite `btoa`
  reads `b>a`; an infinite direction reads no column.
- [`makepriceinterco`](@ref) uses both directional transfer series and the
  foreign-zone spot price. Each can be supplied explicitly or read from its
  Excel fallback. Spot prices and node-interconnection availability
  multipliers are rounded to two decimal places. price-interconnection
  transfer series keep the default six-digit rounding unless overridden.

POSY2 does not impose bounds on capacity-factor or transfer-multiplier columns
at read time. Validate such data before a production run.

## Full-year Hourly Assumption

Nosy supports custom and heterogeneous meshes, but several POSY2 builders and
reports currently assume a non-leap year of 8,760 hourly values. Flat annual
demands divide by 8,760, fixed-profile EVs construct 8,760 entries, nuclear
reload logic iterates over 8,760 hours, and the Excel report labels 8,760 time
rows.

Use 8,760-value workbook columns with Nosy's default
[`TimeMesh`](https://oecd-nea.github.io/Nosy.jl/dev/concepts/time/) for the
documented full-year workflow. A different mesh may work for an individual
builder that has no hard-coded annual logic, but it is not supported uniformly
across POSY2.

!!! note
    The workbooks in `data` are neutral documentation inputs, not calibrated
    scenario projections. Technology CAPEX, lifetime, construction, and
    decommissioning assumptions are based on the IEA/NEA report *Projected
    Costs of Generating Electricity 2020 Edition*. All documentation
    time-series values and geographic labels are synthetic and reproducibly
    generated. The smaller files in `test/data` remain contract fixtures for
    automated tests.

## Direct Reader API

Builders normally use snapshot-based lookups. Direct readers are useful for
validation and diagnostics:

```julia
techbook = readtechdata("tech_data.xlsx"; data_dir=options.data_dir)
gettechparam(techbook, "CCGT", "fuel_cost", "dispatchable", 6)

seriesbook = readtimeseries(
    "time_series.xlsx";
    data_dir=options.data_dir,
)
gettimeseries(seriesbook, "country1", "demand", 6)
```

The final positional argument is the number of rounding digits. Snapshot
overloads default to six digits and expose it as a keyword:

```julia
gettechparam(snapshot, "CCGT", "fuel_cost", "dispatchable"; digits=6)
gettimeseries(snapshot, "country1", "demand"; digits=6)
```
