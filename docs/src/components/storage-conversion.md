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
decision. A real `cap_reservoir` fixes `level` capacity; `nothing` deliberately
leaves the stored-energy level unlimited.

Inflow comes from sheet `reservoir_inflow_<weatheryear>`, column `<zone>`.
`inflow=nothing` uses the profile multiplied by `intake_mult`, `inflow=0`
omits natural inflow, and another numeric value scales the profile by
`inflow * intake_mult`. With `renormalize=true`, the series is first divided
by its annual sum before that scaling. The sum must be strictly positive;
otherwise the builder raises an `ArgumentError` instead of creating `NaN`
inflows.

`eff` applies to grid charging; natural inflow and discharge have unit
efficiency. In `tech_mode=:excel`, omitted technical and cost values come from
the `storage` column named by `techkey`. In `:arguments` mode, efficiency
defaults to one and costs to zero. Lifetime and construction data are resolved
only when overnight cost is nonzero, and the decommissioning profile only when
both overnight and decommissioning costs are nonzero. `gridlosses` adds a
proportional linked input flow. Costs are attached to discharge capacity.

The generated component is tagged `generation`, `storage`, and `carbonfree`.

## Batteries

[`makebatterystorage`](@ref) creates electricity storage with `input`, `output`, and
`level` ports. `capin` is charging power: a number fixes it and `nothing`
creates a decision bounded by `mincap` and `maxcap`. When `ini` is supplied,
the builder fixes charging power to the matching solved component's capacity.

`duration` links energy level to power capacity. It is structural: it comes
from the `storage` technology column in `:excel` mode and must be supplied in
`:arguments` mode. `eff` sets the storage input efficiency, and `simplified`
selects the corresponding Nosy storage formulation. In `:arguments` mode,
efficiency defaults to one and economic terms to zero; inactive capital and
decommissioning data are not resolved. Investment, connection, fixed O&M,
decommissioning, and variable O&M costs are attached to `input` capacity or
flow. `gridlosses` adds a linked charging loss.

The builder tags batteries as `electricity`, `storage`, and `generation`, so
charging and discharging enter the appropriate Posy2 reports.

## Hydrogen Storage

[`makehydrogenstorage`](@ref) creates a simplified storage component on a
hydrogen node. Capacity is attached to `level`, not to charge or discharge
power. A numeric `cap` fixes level capacity; `nothing` creates a decision
bounded by `mincap` and `maxcap`. With `ini`, a matching component inherits its
fixed capacity, while a missing component is represented by zero capacity.

In `:excel` mode, omitted values come from the `storage` technology column. In
`:arguments` mode, `eff` defaults to one and economic terms to zero; inactive
capital and decommissioning data are not required. Investment, fixed O&M, and
decommissioning are attached to `level`. The
builder intentionally adds neither a duration constraint nor a variable O&M
cost, making it suitable for medium- or long-duration storage whose power is
not sized separately.

The component is named `"$cname $(h2.name)"` and tagged `hydrogen` and
`storage`.

## Electrolysers

[`makeelectrolyser`](@ref) creates a converter with electricity `input` and
hydrogen `output`. The output-to-input ratio is `eff`. In `:excel` mode,
omitted values come from the `electrolysis` technology column. In `:arguments`
mode, `eff` defaults to one and costs to zero; lifetime and construction data
are required only for nonzero overnight cost, and the decommissioning profile
only when decommissioning cost is active.

Capacity and all cost behaviours are attached to electricity `input`. A
numeric `cap` fixes input power; `nothing` creates a decision bounded by
`mincap` and `maxcap`; and `ini` fixes capacity from the matching solved
component. `gridlosses` adds a proportional electricity input flow.

The generated name is `"$cname $(elec.name)"`. Function tags are `demand`,
`electrolysis`, and `hydrogen`, allowing electrical consumption to appear in
demand reporting.

## API Entries

See the [API Reference](../api.md) for [`makehydroreservoir`](@ref),
[`makebatterystorage`](@ref), [`makehydrogenstorage`](@ref), and
[`makeelectrolyser`](@ref).
