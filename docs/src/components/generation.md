# Generation

Generation builders create dispatchable, nuclear, intermittent, and hydro
sources. Costed electricity sources attach annualised investment and
decommissioning costs, fixed operation and maintenance, and the applicable
variable costs.

See [Component Builders](../components.md) for shared naming, workbook,
capacity, port, and tagging conventions.

## Dispatchable Generation

[`makedispatchable`](@ref) creates a source named
`"$cname $(elec.name)"`. Its principal port is electricity `output`, and its
investment, connection, fixed O&M, decommissioning, variable O&M, and direct
fuel costs are attached there.

The common technical and economic defaults come from the technology column
named by `techkey` in sheet `dispatchable`. A numeric `cap` fixes output capacity; `nothing`
creates a capacity decision bounded by `mincap` and `maxcap`. This builder has
one special convention: `cap=0` omits the component and returns `nothing`.
`capacitymultiplier` can impose a time-varying availability on output.

If `fuelnode` is absent, `fuel_cost` is a variable cost on electricity output.
If a fuel node is supplied, the builder instead creates a `fuel` input equal to
electricity output divided by `efficiency`. Non-zero `co2_emission` adds a
linked `co2` output and connects it to the CO2 node; `co2price` prices that
flow.

Setting `uc=true` adds unit commitment, no-load cost, and start-up cost.
`integeruc` selects continuous or integer commitment. The minimum power,
up-time, down-time, start-up duration, and shut-down duration default to rows in
the same workbook column. When `unit_size` is positive, non-zero `ramp_up` and
`ramp_down` values add ramp limits after multiplication by the unit size.

The builder tags the component as `generation` and `dispatchable`.

## Nuclear Generation

[`makenuclear`](@ref) uses the same `dispatchable` sheet and the same principal
electricity, fuel, and CO2 ports. It adds `waste_cost`, supports integer
capacity with `integercap`, and accepts `warmstart` for a capacity decision.
Unlike [`makedispatchable`](@ref), a fixed zero capacity creates a zero-capacity
component rather than omitting it.

Unit commitment may include planned fuel-reload outages. Reloading is active
only when `uc=true`, `reload_fraction_per_year` is positive, and
`reload_duration` is positive. In that case `reloadmask` must be a positive
integer interval supplied by the caller. `startupmask` and `shutdownmask` can
further restrict transitions. Reload fraction and duration default to the
`dispatchable` technology column; `reloadmask` has no workbook default.

The specialised reload constraints apply only when `techkey` is exactly
`Nuclear`, `Nuclear flexible`, or `SMR`. They also assume an 8,760-hour model
horizon. Other `techkey` values may omit those constraints. Use these exact
conventions only for a full non-leap-year study.

The component carries `generation` and `dispatchable` function tags. Direct
emissions are controlled by `co2_emission`; the builder does not infer a
`carbonfree` tag from the technology name.

## Intermittent Generation

[`makeintermittentsource`](@ref) creates a profile source. It reads availability
from sheet `profiles_<weatheryear>`, column
`<techkey>_<electricity-node-name>`. The profile multiplies the `output` capacity.

`cap` fixes capacity; `nothing` creates a decision bounded by `mincap` and
`maxcap`; and `ini` inherits the named component's capacity. Technical and cost
defaults come from the technology column named by `techkey` in sheet `intermittent`.
Non-zero emissions create the same linked CO2 flow as for dispatchable
generation.

The component is tagged `generation`, `intermittent`, and `carbonfree`.
Because the last tag is assigned by the builder, use this constructor only when
that classification is appropriate for the study.

## Run-of-river Hydro

[`makehydroror`](@ref) reads absolute inflow from sheet
`hydro_ror_<weatheryear>`, column `<zone>`. A positive numeric `cap` is required
because the builder divides the inflow by capacity to form a profile. It then
multiplies that profile by `intake_mult` and caps it at one.

Cost defaults come from the technology column named by `techkey` in sheet
`intermittent`; the default column name is `Hydro ror`. Capacity is fixed, not
optimisable. The component is tagged `generation`, `intermittent`, and
`carbonfree`.

## API Entries

See the [API Reference](../api.md) for [`makedispatchable`](@ref),
[`makenuclear`](@ref), [`makeintermittentsource`](@ref), and
[`makehydroror`](@ref).
