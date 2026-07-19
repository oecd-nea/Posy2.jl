# Storage And Conversion

Storage builders move energy across time. Conversion builders couple the
electricity, hydrogen, and heat balances. Their cost basis is not uniform:
battery and electrolyser investment is attached to charging or input power,
while hydrogen-storage investment is attached to stored-energy level.

See [Component Builders](../components.md) for shared naming, workbook,
capacity, port, and tagging conventions.

## Hydro Reservoir

[`makehydroreservoir`](@ref) creates a storage component with up to four flows:

- `natural` is unconnected fixed inflow from the reservoir series;
- `input` is optional grid charging;
- `output` is electricity generation;
- `level` is stored energy.

`cap_discharging` fixes `output` capacity when numeric and creates a capacity
decision when `nothing`. For `cap_charging`, a positive number fixes `input`
capacity, zero disables grid charging, and `nothing` creates an input-capacity
decision. A numeric `cap_reservoir` fixes `level` capacity; any other value
leaves the level without a capacity behaviour.

Inflow comes from sheet `reservoir_inflow_<weatheryear>`, column `<zone>`.
`inflow=nothing` uses the profile multiplied by `intake_mult`, `inflow=0`
omits natural inflow, and another numeric value scales it. With
`renormalize=true`, the series is first divided by its annual sum and
multiplied by `intake_mult`.

`eff` defaults to `roundtrip_eff` in technology column `tech` of sheet
`storage`. It applies to grid charging; natural inflow and discharge have unit
efficiency. `gridlosses` adds a proportional linked input flow. Cost defaults
come from the same technology column and are attached to discharge capacity.

The generated component is tagged `generation`, `storage`, and `carbonfree`.

## Batteries

[`makebatteries`](@ref) creates electricity storage with `input`, `output`, and
`level` ports. `capin` is charging power: a number fixes it and `nothing`
creates a decision bounded by `mincap` and `maxcap`. When `ini` is supplied,
the builder fixes charging power to the matching solved component's capacity.

`duration` links energy level to power capacity. `eff` sets the storage input
efficiency, and `simplified` selects the corresponding Nosy storage
formulation. These values default to `duration` and `roundtrip_eff` in the
`storage` technology column. Investment, connection, fixed O&M,
decommissioning, and variable O&M costs are attached to `input` capacity or
flow. `gridlosses` adds a linked charging loss.

The builder tags batteries as `electricity`, `storage`, and `generation`, so
charging and discharging enter the appropriate POSY2 reports.

## Hydrogen Storage

[`makehydrogenstorage`](@ref) creates a simplified storage component on a
hydrogen node. Capacity is attached to `level`, not to charge or discharge
power. A numeric `cap` fixes level capacity; `nothing` creates a decision
bounded by `mincap` and `maxcap`. With `ini`, a matching component inherits its
fixed capacity, while a missing component is represented by zero capacity.

`eff` defaults to `roundtrip_eff` in the `storage` technology column.
Investment, fixed O&M, and decommissioning are also attached to `level`. The
builder intentionally adds neither a duration constraint nor a variable O&M
cost, making it suitable for medium- or long-duration storage whose power is
not sized separately.

The component is named `"$cname $(h2.name)"` and tagged `hydrogen` and
`storage`.

## Electrolysers

[`makeelectrolyser`](@ref) creates a converter with electricity `input` and
hydrogen `output`. The output-to-input ratio is `eff`, which defaults to
`efficiency` in technology column `tech` of sheet `electrolysis`.

Capacity and all cost behaviours are attached to electricity `input`. A
numeric `cap` fixes input power; `nothing` creates a decision bounded by
`mincap` and `maxcap`; and `ini` fixes capacity from the matching solved
component. `gridlosses` adds a proportional electricity input flow.

The generated name is `"$cname $(elec.name)"`. Function tags are `demand`,
`electrolysis`, and `hydrogen`, allowing electrical consumption to appear in
demand reporting.

## High-temperature Electrolysers

[`makeHTelectrolyser`](@ref) has the same electrical input, hydrogen output,
capacity semantics, efficiency, and `electrolysis` workbook defaults. It also
adds a `heat` input equal one-to-one with electricity input. Pair it with a
heat-supplying component such as [`makesmr`](@ref) and connect both to the same
heat node.

This builder carries the `electrolysis` and `hydrogen` function tags. Unlike
the conventional electrolyser, it does not add the `demand` function tag;
electrolysis-specific reporting still recognises it.

## API Entries

See the [API Reference](../api.md) for [`makehydroreservoir`](@ref),
[`makebatteries`](@ref), [`makehydrogenstorage`](@ref),
[`makeelectrolyser`](@ref), and [`makeHTelectrolyser`](@ref).
