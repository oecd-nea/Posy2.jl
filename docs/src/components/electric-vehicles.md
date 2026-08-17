# Electric Vehicles

[`makeEV`](@ref) creates fixed or flexible electric-vehicle demand. See
[Component Builders](../components.md) for shared naming, workbook, and port
conventions, and [Tags And Post-Processing](../concepts/tags.md) for tagging
and reporting. Each mode's diagram follows the conventions in [Reading The Port
Diagrams](../components.md#Reading-The-Port-Diagrams).

!!! warning "Unstable EV API"
    The EV API is not fixed yet. The modes, keyword arguments, component and
    port structure, and reporting semantics may change substantially in later
    Posy2 versions.

Exactly one of `fixed_profile`, `smart_charging`, and `vehicle_to_grid` must be
true.

## Fixed Profile

The fixed mode creates a conventional demand component. `offhours1` and
`offhours2` give zero-based hours of day for the winter and summer patterns;
`minratio` scales demand in those hours. `days_threshold` locates the boundary
between the first winter segment and summer. The generated 365-day profile is
normalised to the annual consumption `yearly`, so its hourly values always sum
to `yearly` exactly. Off-hour indices must be unique, and a schedule leaving no
charging hour at all (every hour an off-hour with `minratio=0`) is rejected.

This mode requires `offhours1`, `offhours2`, and `minratio`, but performs no
workbook lookup. It can add the same proportional `grid losses` port as
[`makedemand`](@ref).

![Ports of an EV component in fixed-profile mode](../assets/component-ev-fixed.svg)

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

## Smart Charging And Vehicle To Grid

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

![Ports of an EV component in smart-charging and vehicle-to-grid modes](../assets/component-ev-flexible.svg)

Tags for all EV modes: `:tech => cname`, `:zone => elec.name`, and the function
tags `electricity`, `demand`, and `ev`. Vehicle-to-grid mode also receives the
function tag `generation`, so its discharge appears in production reporting.

!!! note
    EV profiles and level constraints currently use a 365-day, 8,760-hour
    convention. Use a full non-leap-year hourly mesh for these modes.

```@docs; canonical=false
makeEV
```
