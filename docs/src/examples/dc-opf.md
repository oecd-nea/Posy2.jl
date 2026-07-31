# DC OPF

Four electricity zones sit on a ring of AC [`makenodeinterco`](@ref) links, with
one extra diagonal `A-C`. With `dcopf=false` the mesh is a **transport** model:
a network flow problem that enforces nodal balance (and capacity limits) but not
Kirchhoff's voltage law. With `dcopf=true` and [`applydcopf!`](@ref), POSY2 adds
KVL on every independent AC cycle, so the study becomes a DC optimal power-flow
approximation of the AC mesh: corridor flows must obey the split implied by the
line susceptances.

Use transport when nodal balance and transfer limits are enough for the study.
Turn on DC OPF when corridor flows must reflect AC network physics—how exchanges
split across parallel paths under KVL and the line susceptances. See
[DC Power Flow](../concepts/optimizing.md#DC-Power-Flow) for the signed-flow
definition and the cycle constraints used by [`applydcopf!`](@ref).

This page runs three closely related studies so that difference is easy to read:

1. transport (`dcopf=false`, all AC, including an AC diagonal);
2. DC OPF on the same AC mesh (`dcopf=true` and [`applydcopf!`](@ref));
3. DC OPF again, but with the diagonal built as controllable HVDC (`dc=true`).

Link capacities are `Inf` only to keep the teaching model simple; in a real
study you would pass finite NTC values the same way. The ring plus the AC
diagonal gives two independent AC loops, so [`applydcopf!`](@ref) adds two KVL
constraints per time step when that diagonal is AC.

After each solve, [`printsnapshot`](@ref) writes the standard POSY2 Excel
report under `results/`—one workbook per scenario. In `Annual values (all)`,
the **Interconnection volume** tables (total, AC, and DC) give a compact
summary of annual corridor exchanges and make scenario-to-scenario comparison
straightforward.

## Transport (no KVL)

With `dcopf=false` there is no need for susceptances or [`applydcopf!`](@ref).
The solver may pick any feasible transport pattern.

```jldoctest dc_opf_transport; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    dcopf=false,
)))

a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
c = Node("C", EnergyCarrier("electricity C", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
d = Node("D", EnergyCarrier("electricity D", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "C", c, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "D", d, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)

makedispatchable(
    "CCGT", "CCGT", a, co2, snapshot;
    cap=10.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=47.06,
    co2_emission=0.0,
    unit_size=0.0,
)

# Ring of AC links (Inf capacities for a simple teaching case).
makenodeinterco("IC", a, b, Inf, Inf, snapshot; dc=false)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; dc=false)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; dc=false)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; dc=false)
# AC diagonal (second loop).
makenodeinterco("IC", a, c, Inf, Inf, snapshot; dc=false)

optimize!(snapshot, cost(snapshot))
result_transport = extract(snapshot)

# output

Snapshot with 10 component(s) and 4 node(s)

```

```jldoctest dc_opf_transport
julia> printsnapshot(result_transport, "transport.xlsx")
```

That creates `results/transport.xlsx`. The figure below is the
**Interconnection volume** section of that workbook (TWh/y). Every link is AC,
so the DC volume table is empty and all reported interconnection volume is AC.

![Transport interconnection volume from printsnapshot](../assets/transport.png)

**What to read.** Zone A hosts the only plant, so most energy leaves A
(`A -> B`, `A -> C`, `A -> D`). Transport does not enforce KVL, so several
feasible flow patterns satisfy exactly the same generation and demand. The
solver may also use reverse and cross exchanges such as `B -> C`, `C -> B`, and
`D -> C`; those are loop (circulating) flow degrees of freedom that nodal
balance alone does not fix. The workbook total is about `0.038 TWh/y` of
directed corridor energy, above the net demand served in B, C, and D alone,
because such exchanges are counted on more than one corridor.

## With DCOPF

Same AC network, but `dcopf=true` and a real [`applydcopf!`](@ref) call. Set a
negative susceptance on every AC link, finish the network, then call
[`applydcopf!`](@ref) before optimisation. The flag alone does not add KVL
constraints.

```jldoctest dc_opf; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    dcopf=true,
)))

a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
c = Node("C", EnergyCarrier("electricity C", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
d = Node("D", EnergyCarrier("electricity D", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "C", c, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "D", d, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)

makedispatchable(
    "CCGT", "CCGT", a, co2, snapshot;
    cap=10.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=47.06,
    co2_emission=0.0,
    unit_size=0.0,
)

# Ring of AC links (Inf capacities for a simple teaching case).
makenodeinterco("IC", a, b, Inf, Inf, snapshot; dc=false, susceptance=-1.0)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; dc=false, susceptance=-2.0)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; dc=false, susceptance=-1.5)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; dc=false, susceptance=-2.5)
# AC diagonal (second loop).
makenodeinterco("IC", a, c, Inf, Inf, snapshot; dc=false, susceptance=-3.0)

applydcopf!(snapshot)
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 10 component(s) and 4 node(s)

```

Generation is unchanged: the plant still supplies a flat 4 MW (one megawatt of
demand in each zone), or `35040 MWh` over the year. Transport determines only
the net exchange required to satisfy nodal balance. DC OPF additionally
enforces Kirchhoff's voltage law, which determines how those exchanges are
distributed across the meshed AC network according to the line susceptances—
so the path of that energy through the mesh changes even though generation and
demand do not.

```jldoctest dc_opf
julia> balance(result, "CCGT A", :output, energy; collapse=true, aggregate=true)
35040.0

julia> printsnapshot(result, "dc-opf.xlsx")
```

![DC OPF interconnection volume from printsnapshot](../assets/dc-opf.png)

**Transport vs DC OPF.** Put `transport.xlsx` and `dc-opf.xlsx` next to each
other (or compare the two figures). Both scenarios use only AC corridors, so
the DC volume table is empty and all reported interconnection volume is AC.
Transport has many feasible flow solutions that satisfy nodal balance. DC OPF
restricts this solution space by enforcing KVL, so the resulting flow pattern
is determined by the network susceptances. In the tables:

- under DC OPF the matrix is much quieter: exports leave A on `A -> B`,
  `A -> C`, and `A -> D`, with only a small `C -> B` exchange;
- the directed total falls to about `0.03 TWh/y` (from about `0.038 TWh/y` in
  transport): many transport-feasible patterns with extra loop-flow degrees of
  freedom are no longer admissible once KVL holds;
- individual corridors move: for example `A -> B` rises while `A -> D` falls
  relative to the transport screenshot, as the two AC loops share flow
  according to the susceptances rather than an arbitrary LP extreme point.

Same plants and demands, different network model; the Excel volume tables make
that comparison direct.

## Controllable DC links

[`makenodeinterco`](@ref) tags each link as AC (`dc=false`, the default) or DC
(`dc=true`). Only AC links enter the susceptance matrix and the cycle basis used
by [`applydcopf!`](@ref).

That exclusion matches how HVDC behaves in a real grid. An AC corridor’s flow is
tied to the voltage-angle differences around meshed lines, so it must satisfy
KVL on every independent AC cycle. A controllable DC corridor (for example an
HVDC link with converter stations) is different: operators set or schedule the
transfer directly, and the line does not follow an AC phase-angle loop law.
Putting that corridor into the AC cycle basis would invent a fake voltage
constraint and distort both the loop count and the KVL equations. POSY2
therefore keeps DC links in the energy balance and capacity limits, but outside
the AC susceptance graph.

Replace the AC diagonal with a DC link and only the ring remains in the AC
cycle basis—one AC loop, even though five physical corridors exist. The DC
corridor still carries energy; it is simply outside KVL.

```jldoctest dc_opf_dc; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    dcopf=true,
)))

a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
c = Node("C", EnergyCarrier("electricity C", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
d = Node("D", EnergyCarrier("electricity D", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "C", c, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "D", d, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)

makedispatchable(
    "CCGT", "CCGT", a, co2, snapshot;
    cap=10.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=47.06,
    co2_emission=0.0,
    unit_size=0.0,
)

ic_ab = makenodeinterco("IC", a, b, Inf, Inf, snapshot; dc=false, susceptance=-1.0)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; dc=false, susceptance=-2.0)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; dc=false, susceptance=-1.5)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; dc=false, susceptance=-2.5)
hvdc = makenodeinterco("HVDC", a, c, Inf, Inf, snapshot; dc=true)

applydcopf!(snapshot)
optimize!(snapshot, cost(snapshot))
result_dc = extract(snapshot)

# output

Snapshot with 10 component(s) and 4 node(s)

```

```jldoctest dc_opf_dc
julia> hastag(ic_ab, :function, "AC"), hastag(hvdc, :function, "DC")
(true, true)

julia> printsnapshot(result_dc, "dc-opf-hvdc.xlsx")
```

![DC OPF with HVDC diagonal: interconnection volume split by AC and DC](../assets/dc-opf-hvdc.png)

**What the Excel split shows.** Now the three volume blocks disagree on purpose:

- **Interconnection volume (DC)** is almost only `A -> C` (about `0.02 TWh/y`):
  that is the HVDC diagonal, scheduled outside KVL;
- **Interconnection volume (AC)** keeps the ring flows (about `0.018 TWh/y`)
  that still obey the single AC loop;
- the combined total (about `0.038 TWh/y`) is AC + DC.

So the same `printsnapshot` workflow that compared transport with DC OPF also
makes the AC/DC modelling rule visible: tags decide which corridors enter KVL,
and the annual tables mirror that split without extra scripting.

A radial AC network has no cycle to constrain. Calling [`applydcopf!`](@ref)
when `dcopf=true` but no AC loop exists emits a warning and adds no KVL rows.
