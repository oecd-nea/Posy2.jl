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

In `tech_mode=:excel`, common technical and economic defaults come from the
technology column named by `techkey` in sheet `dispatchable`. In
`tech_mode=:arguments`, additive costs and emissions default to zero, linked
fuel defaults to lossless efficiency, and unit sizing and ramping default to
disabled. Capital lifetime and profiles are required only when their associated
cost is active. A numeric `cap` fixes output capacity; a JuMP variable or affine
expression reuses an external capacity decision; and `nothing` creates a new
decision. `mincap` and `maxcap` bound either variable form. This builder has one
special convention: numeric `cap=0` omits the component and returns `nothing`.
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
further restrict transitions. In `:excel` mode, reload fraction and duration
default to the `dispatchable` technology column. In `:arguments` mode they
default to zero, disabling reload outages; `reloadmask` has no workbook default
and is needed only when positive reload fraction and duration activate the
feature. Economic terms and emissions also default to zero in `:arguments`
mode, and a positive `unit_size` is required only for unit commitment or
integer capacity expansion.

Capacity follows the common numeric, external-expression, and `nothing`
semantics. For an external expression, `mincap` and `maxcap` constrain that
expression and `ini` is ignored. Nosy does not allow `warmstart` with an
external expression. With `integercap=true`, a `VariableRef` is made integer,
whereas an `AffExpr` is rejected. In particular, `unit_size` does not make an
external variable a number-of-units variable; represent that explicitly as
`unit_size * integer_units` when unit-block integrality is required.

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
Workbook lookup requires an explicit `weatheryear`; the keyword defaults to
`nothing` and is unused when `profile` is supplied directly.

Numeric `cap` fixes capacity; a JuMP variable or affine expression reuses an
external capacity decision; `nothing` creates a new decision; and `ini`
inherits the named component's capacity. `mincap` and `maxcap` bound either
variable form. In `:excel` mode,
technical and cost defaults come from the technology column named by `techkey`
in sheet `intermittent`. In `:arguments` mode, costs and emissions default to
zero and inactive capital data are not required. The production profile
remains structural whenever capacity is active.
Non-zero emissions create the same linked CO2 flow as for dispatchable
generation. The component is tagged `generation` and `intermittent`; it also
receives `carbonfree` when `co2_emission` is zero.

## Run-of-river Hydro

[`makehydroror`](@ref) reads an intake shape from sheet
`hydro_ror_<weatheryear>`, column `<zone>`. The builder normalizes the shape to
sum to one, distributes `intake` over it, and limits hourly output by both that
intake envelope and installed capacity.
Workbook lookup requires an explicit `weatheryear`; the keyword defaults to
`nothing` and is unused when `intake_profile` is supplied directly.

In `:excel` mode, cost defaults come from the technology column named by
`techkey` in sheet `intermittent`; the default column name is `Hydro ror`. In
`:arguments` mode costs default to zero and inactive capital data are not
required. A numeric `cap` fixes output capacity; `cap=nothing` creates a new
capacity decision; and a JuMP variable or affine expression reuses an external
decision. `mincap` and `maxcap` bound either variable form. The intake profile
remains independent of capacity. The component is tagged `generation`,
`intermittent`, and `carbonfree`.

## API Entries

See the [API Reference](../api.md) for [`makedispatchable`](@ref),
[`makenuclear`](@ref), [`makeintermittentsource`](@ref), and
[`makehydroror`](@ref).
