# Demand And Flexibility

Demand-side builders cover fixed consumption, annually constrained flexible
consumption, electric-vehicle charging, and virtual demand response. All
components are created and connected immediately.

See [Component Builders](../components.md) for shared naming, workbook, cost,
capacity, port, and tagging conventions.

## Electricity Demand

[`makedemand`](@ref) creates a fixed Nosy demand with the name
`"$cname $(n.name)"`. Its `input` profile is

```math
d_t = c p_t + D / 8760,
```

where `c` is `coeff`, `p_t` is the workbook series selected by `zone`, and `D`
is `yearlyconstant`. `shift` circularly shifts the workbook series before the
flat term is added. Setting `coeff=0` suppresses the workbook lookup, which is
useful for self-contained examples and purely flat demand.

When `gridlosses` is non-zero, the builder adds a linked `grid losses` input
proportional to demand. The value must lie in `[0, 1)`. The component receives
the `electricity` and `demand` function tags, as well as `:tech=>cname` and
`:zone=>n.name`.

The workbook series is read from sheet `demand`, column `<zone>`. With the
standard hourly MW/MWh convention, `yearlyconstant` is in MWh/year.

## Hydrogen Demand

[`makeflathydrogendemand`](@ref) creates a fixed `input` of `val / 8760` at a
hydrogen node. [`makeflexhydrogendemand`](@ref) instead creates a flexible
`input` whose sum over the model year must equal `val`. Both builders therefore
take an annual hydrogen-energy quantity, but only the flat builder fixes its
hourly shape.

The generated name is `"$cname $(n.name)"`. Both components carry the
`hydrogen` and `demand` function tags. They do not read a workbook and do not
add a cost or capacity behaviour.

## Electric Vehicles

!!! warning "Unstable EV API"
    The EV API is not fixed yet. The modes, keyword arguments, component and
    port structure, and reporting semantics may change substantially in later
    Posy2 versions.

[`makeEV`](@ref) supports three mutually exclusive modes. Exactly one of
`fixed_profile`, `smart_charging`, and `vehicle_to_grid` must be true.

### Fixed Profile

The fixed mode creates a conventional demand component. `offhours1` and
`offhours2` give zero-based hours of day for the winter and summer patterns;
`minratio` scales demand in those hours. `days_threshold` locates the boundary
between the first winter segment and summer. The generated 365-day profile is
normalised to the annual consumption `yearly`.

This mode requires `offhours1`, `offhours2`, and `minratio`, but performs no
workbook lookup. It can add the same proportional `grid losses` port as
[`makedemand`](@ref).

```julia
makeEV(
    "EV", 50_000.0, electricity, snapshot;
    fixed_profile=true,
    smart_charging=false,
    vehicle_to_grid=false,
    offhours1=0:5,
    offhours2=0:5,
    minratio=0.2,
)
```

### Smart Charging And Vehicle To Grid

The flexible modes represent the connected vehicle fleet as storage. Both use
these time-series columns for `zone`:

- `EV_charging_availability` controls the available charging power and storage
  level;
- `EV_driving_profile` allocates annual driving consumption across the year.

Per-vehicle values come from the technology column named by `techkey` in the
`storage` sheet:
`charging_eff`, `self_discharge`, `min_level_morning`, `max_charging_power`,
`max_dispatch_power`, `battery_capacity`, and `yearly_consumption`. Each has a
corresponding keyword override. The fleet size is `yearly` divided by annual
consumption per vehicle, and the per-vehicle limits are scaled by that size.
`max_dispatch_power` is resolved only in vehicle-to-grid mode; smart charging
does not require it.

In `tech_mode=:arguments`, charging efficiency defaults to one,
self-discharge and the morning minimum to zero. Maximum charging power,
battery capacity, and yearly consumption per vehicle remain structural and
must be supplied; V2G additionally requires maximum dispatch power. In
`timeseries_mode=:arguments`, omitted charging availability defaults to one,
while the driving profile remains required.

Smart charging exposes a flexible `input`, a `level`, and a fixed unconnected
`driving` output. Vehicle-to-grid mode also exposes `output`, limited by
available dispatch power, and applies `compensation` as a variable output cost.
The morning level constraint requires the connected fleet to hold at least
`min_level_morning` of available battery capacity at 7 am each day.

All EV modes carry `electricity`, `demand`, and `ev` function tags. V2G also
carries `generation`, so its discharge appears in production reporting.

!!! note
    EV profiles and level constraints currently use a 365-day, 8,760-hour
    convention. Use a full non-leap-year hourly mesh for these modes.

## Demand Response

[`makedemandresponse`](@ref) represents demand response as negative
consumption at the electricity node. Its positive `output` is an unconnected
accounting flow used for capacity, activation cost, and reporting. A linked
`negative consumption` input equal to
`-(1 - elec.losses) * output` is connected instead, so the existing consumption
components remain unchanged while demand response enters the nodal balance
from the demand side. With zero node losses this is exactly `-output`. A
numeric `capa` adds fixed response capacity; `nothing` leaves the positive
output unconstrained by a capacity behaviour.

`cost` is the activation cost per unit of the positive `output` flow and is
applied directly. `type` selects the variable-cost category used by reports
and defaults to `:volDR`.

The generated component is named `"$cname $(elec.name)"` and carries the
`virtual` and `demandresponse` function tags.

## API Entries

The complete keyword lists and validation rules are in the
[API Reference](../api.md): [`makedemand`](@ref),
[`makeflathydrogendemand`](@ref), [`makeflexhydrogendemand`](@ref),
[`makeEV`](@ref), and [`makedemandresponse`](@ref).
