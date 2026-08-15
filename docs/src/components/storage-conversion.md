# Storage And Conversion

Storage builders move energy across time. Conversion builders couple the
electricity, hydrogen, and heat balances. Their cost basis is not uniform:
battery and electrolyser investment is attached to charging or input power,
while hydrogen-storage investment is attached to stored-energy level.

See [Component Builders](../components.md) for shared naming, workbook,
capacity, port, and tagging conventions.

## Hydro Reservoir

[`makehydroreservoir`](@ref) creates a storage component with up to five flows:

- `natural` is unconnected fixed intake from the reservoir series;
- `input` is optional grid charging;
- `output` is electricity generation;
- `spill` is optional unconnected release, enabled by `spillage`;
- `level` is stored energy.

Each of `cap_discharging`, `cap_charging`, and `cap_reservoir` accepts a JuMP
variable or affine expression as externally defined capacity. Numeric
discharging and charging capacities remain fixed, and `nothing` creates a new
decision. Numeric zero charging disables the grid-charging branch; a symbolic
charging capacity creates that branch because it may be positive. A finite
numeric `cap_reservoir` fixes `level` capacity, `nothing` creates a level
decision, and `Inf` (the default) leaves the stored-energy level unlimited.

For example, use `cap_reservoir=12_000.0` for a fixed 12 GWh reservoir,
`cap_reservoir=nothing` to let the model choose its energy capacity, or omit the
keyword (equivalently, pass `Inf`) for an unlimited level.

Storage is periodic, so without a spill flow every unit of natural intake must
eventually be turbined. That can force uneconomic generation, or make the
reservoir infeasible when intake, turbine capacity, and level capacity do not
fit together. `spillage=true` adds an unlimited, uncosted `spill` output that
absorbs the excess. It is opt-in: the default `spillage=false` keeps the forced
use of all inflow. Spilled energy is reported by the hourly sheet's
`Total spillage` and `spillage <component>` columns.

The intake profile comes from sheet `reservoir_inflow_<weatheryear>`, column `<zone>`.
When `intake_profile` is omitted and intake is enabled, `weatheryear` must be
provided explicitly. It defaults to `nothing` and is unused with an explicit
profile or with `intake=0`. The profile is always normalized to sum to one,
then scaled by the requested total `intake`.

`eff` defaults to `roundtrip_eff` in the technology column named by `techkey`
of sheet `storage`. It applies to grid charging; natural intake and discharge have unit
efficiency. `gridlosses` adds a proportional linked input flow. Cost defaults
come from the same technology column and are attached to discharge capacity.

The generated component is tagged `generation`, `storage`, and `carbonfree`.

## Batteries

[`makebatterystorage`](@ref) creates electricity storage with `input`, `output`, and
`level` ports. `cap` is charging power: a number fixes it, a JuMP variable or
affine expression reuses an external decision, and `nothing` creates a new
decision. `mincap` and `maxcap` bound either variable form. When `ini` is supplied,
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
power. A numeric `cap` fixes level capacity; a JuMP variable or affine
expression reuses an external decision; and `nothing` creates a new decision.
`mincap` and `maxcap` bound either variable form. With `ini`, a matching
component inherits its fixed capacity, while a missing component is represented
by zero capacity.

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
numeric `cap` fixes input power; a JuMP variable or affine expression reuses an
external decision; `nothing` creates a new decision; and `ini` fixes capacity
from the matching solved component. `mincap` and `maxcap` bound either variable
form. `gridlosses` adds a proportional electricity input flow.

The generated name is `"$cname $(elec.name)"`. Function tags are `demand`,
`electrolysis`, and `hydrogen`, allowing electrical consumption to appear in
demand reporting.

## API Entries

See the [API Reference](../api.md) for [`makehydroreservoir`](@ref),
[`makebatterystorage`](@ref), [`makehydrogenstorage`](@ref), and
[`makeelectrolyser`](@ref).
