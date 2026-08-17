# Storage

Storage builders move electricity across time. Battery investment is attached
to charging power, while reservoir investment is attached to discharge power.
Hydrogen conversion and storage are documented on the
[Hydrogen](hydrogen.md) page.

See [Component Builders](../components.md) for shared naming, workbook,
capacity, and port conventions, and [Tags And
Post-Processing](../concepts/tags.md) for tagging and reporting.

## Hydro Reservoir

[`makehydroreservoir`](@ref) creates a storage component with up to five flows:

- `natural` is unconnected fixed intake from the reservoir series;
- `input` is grid charging, always present and possibly at zero capacity;
- `output` is electricity generation;
- `spill` is optional unconnected release, enabled by `spillage`;
- `level` is stored energy.

Each of `cap_discharging`, `cap_charging`, and `cap_reservoir` accepts a JuMP
variable or affine expression as externally defined capacity, an extracted snapshot
to inherit the matching component's capacity on that port, a number to fix it,
or `nothing` to create a new decision. Each has its own `mincap_*`/`maxcap_*`
bounds. The grid-charging branch always exists: numeric zero charging gives it
a zero capacity, so a turbine-only reservoir still reports a charging flow of
zero. A finite numeric `cap_reservoir` fixes `level` capacity, `nothing`
creates a level decision, and `Inf` (the default) leaves the stored-energy
level unlimited by adding no level capacity behaviour.

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

Tags: `:tech => cname`, `:zone => elec.name`, and the function tags `generation`,
`storage`, and `carbonfree`.

```@docs; canonical=false
makehydroreservoir
```

## Batteries

[`makebatterystorage`](@ref) creates electricity storage with `input`, `output`, and
`level` ports. `cap` is charging power: a number fixes it, a JuMP variable or
affine expression reuses an external decision, `nothing` creates a new
decision, and an extracted snapshot fixes charging power to the matching
component's capacity. `mincap` and `maxcap` bound either variable form.

`duration` links energy level to power capacity. It is structural: it comes
from the `storage` technology column in `:excel` mode and must be supplied in
`:arguments` mode. `eff` sets the storage input efficiency, and `simplified`
selects the corresponding Nosy storage formulation. In `:arguments` mode,
efficiency defaults to one and economic terms to zero; inactive capital and
decommissioning data are not resolved. Investment, connection, fixed O&M,
decommissioning, and variable O&M costs are attached to `input` capacity or
flow. `gridlosses` adds a linked charging loss.

Tags: `:tech => cname`, `:zone => elec.name`, and the function tags
`electricity`, `storage`, and `generation`. These tags make charging and
discharging enter the appropriate Posy2 reports.

```@docs; canonical=false
makebatterystorage
```
