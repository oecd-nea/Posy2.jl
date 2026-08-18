# DC OPF

Four electricity zones A–B–C–D sit on an AC ring of
[`makenodeinterco`](@ref) lines, with one extra diagonal A–C. A single CCGT
on A supplies flat 1 MW demand in every zone. Left alone, the mesh is a
transport model: a network flow problem that enforces nodal balance (and
capacity limits) but not Kirchhoff's voltage law. Calling
[`applydcopf!`](@ref) adds KVL on every independent AC cycle, so the
study becomes a DC optimal power-flow approximation of the AC mesh: corridor
flows follow the split implied by the line susceptances.

Use transport when nodal balance and transfer limits are enough for the study.
Turn on DC OPF when corridor flows must reflect AC network physics—how
exchanges split across parallel paths under KVL and the line susceptances. See
[DC Power Flow](../concepts/optimizing.md#DC-Power-Flow) for the signed-flow
definition and the cycle constraints used by [`applydcopf!`](@ref).

This page keeps the same plants and demand and changes only the network:

1. transport (no [`applydcopf!`](@ref), all AC, including an AC diagonal);
2. DC OPF on the same AC mesh ([`applydcopf!`](@ref) after the network is built);
3. DC OPF again, but with the diagonal built as controllable HVDC (`dc=true`).

After each solve, [`printsnapshot`](@ref) writes the standard Posy2 workbook
report under `results/`—one workbook per scenario. In `Annual values (all)`,
the Interconnection volume tables (total, AC, and DC) summarise annual
corridor exchanges. The markdown tables on this page match that workbook
section.

## Transport (no KVL)

Without [`applydcopf!`](@ref) there is no need for susceptances.
The solver may pick any feasible transport pattern.

```jldoctest dc_opf_transport; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:excel,
    timeseries_mode=:arguments,
)))

# Electricity zones and CO2 sink
a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
c = Node("C", EnergyCarrier("electricity C", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
d = Node("D", EnergyCarrier("electricity D", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Flat 1 MW demand in each zone
makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "C", c, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "D", d, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)

# 10 MW CCGT on A; costs from the technology workbook
makedispatchable("CCGT", "CCGT", a, co2, snapshot; cap=10.0, unit_size=0.0)

# AC ring with Inf capacity
makenodeinterco("IC", a, b, Inf, Inf, snapshot)
makenodeinterco("IC", b, c, Inf, Inf, snapshot)
makenodeinterco("IC", c, d, Inf, Inf, snapshot)
makenodeinterco("IC", d, a, Inf, Inf, snapshot)
# AC diagonal A–C
makenodeinterco("IC", a, c, Inf, Inf, snapshot)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result_transport = extract(snapshot)

# output

Snapshot with 10 component(s) and 5 node(s)

```

```jldoctest dc_opf_transport
julia> printsnapshot(result_transport, "transport.xlsx")
```

That creates `results/transport.xlsx`. The directed corridor volumes below
match the Interconnection volume table in `Annual values (all)` (TWh/y).
Every line is AC, so the DC volume block in the workbook is empty.

| From \\ To | A | B | C | D | Total |
| --- | --- | --- | --- | --- | --- |
| A |  | 0.003 | 0.012 | 0.011 | 0.026 |
| B | 0 |  | 0.001 |  | 0.001 |
| C | 0 | 0.007 |  | 0.001 | 0.007 |
| D | 0 |  | 0.003 |  | 0.003 |
| Total | 0 | 0.01 | 0.016 | 0.012 | 0.038 |

Zone A hosts the only plant, so energy is exported from A to the other zones
(A -> B, A -> C, A -> D). Without KVL the solver may choose among several
feasible transport patterns. The table above is the annual corridor volume for
this solve.

## DC OPF (with KVL)

Same AC network, but with [`applydcopf!`](@ref). Set a negative series susceptance
(``B\approx-1/X`` for inductive lines) on every AC line, then call
[`applydcopf!`](@ref) once the whole network is built and before optimisation.

```jldoctest dc_opf; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:excel,
    timeseries_mode=:arguments,
)))

# Electricity zones and CO2 sink
a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
c = Node("C", EnergyCarrier("electricity C", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
d = Node("D", EnergyCarrier("electricity D", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Flat 1 MW demand in each zone
makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "C", c, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "D", d, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)

# 10 MW CCGT on A; costs from the technology workbook
makedispatchable("CCGT", "CCGT", a, co2, snapshot; cap=10.0, unit_size=0.0)

# AC ring with susceptances
makenodeinterco("IC", a, b, Inf, Inf, snapshot; susceptance=-1.0)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; susceptance=-2.0)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; susceptance=-1.5)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; susceptance=-2.5)
# AC diagonal A–C with susceptance
makenodeinterco("IC", a, c, Inf, Inf, snapshot; susceptance=-3.0)

# Apply KVL, then optimise
applydcopf!(snapshot)
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 10 component(s) and 5 node(s)

```

```jldoctest dc_opf
julia> printsnapshot(result, "dc-opf.xlsx")
```

That writes `results/dc-opf.xlsx`. The Interconnection volume table in
`Annual values (all)` matches the corridor volumes below (TWh/y):

| From \\ To | A | B | C | D | Total |
| --- | --- | --- | --- | --- | --- |
| A |  | 0.006 | 0.012 | 0.009 | 0.026 |
| B | 0 |  | 0 |  | 0 |
| C | 0 | 0.003 |  | 0 | 0.003 |
| D | 0 |  | 0 |  | 0 |
| Total | 0 | 0.009 | 0.012 | 0.009 | 0.03 |

Compared with the transport workbook: plants and demand are the same; what
changes is the network model, and the corridor volumes shift once KVL and the
line susceptances constrain the path through the mesh.

## Controllable DC lines

[`makenodeinterco`](@ref) tags each line as AC (`dc=false`, the default) or DC
(`dc=true`). Only AC lines enter the susceptance matrix and the cycle basis
used by [`applydcopf!`](@ref).

That exclusion matches how HVDC behaves in a real grid. An AC corridor’s flow
is tied to the voltage-angle differences around meshed lines, so it must
satisfy KVL on every independent AC cycle. A controllable DC corridor (for
example an HVDC line with converter stations) is different: operators set or
schedule the transfer directly, and the line does not follow an AC phase-angle
loop law.
Posy2 therefore keeps DC lines in the energy balance and capacity limits, but
outside the AC susceptance graph.

The example below replaces the AC diagonal with HVDC (`dc=true`).

```jldoctest dc_opf_dc; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:excel,
    timeseries_mode=:arguments,
)))

# Electricity zones and CO2 sink
a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
c = Node("C", EnergyCarrier("electricity C", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
d = Node("D", EnergyCarrier("electricity D", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Flat 1 MW demand in each zone
makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "C", c, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)
makedemand("Demand", "D", d, snapshot; coeff=0.0, yearlyconstant=1.0 * 8760)

# 10 MW CCGT on A; costs from the technology workbook
makedispatchable("CCGT", "CCGT", a, co2, snapshot; cap=10.0, unit_size=0.0)

# AC ring with susceptances
makenodeinterco("IC", a, b, Inf, Inf, snapshot; susceptance=-1.0)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; susceptance=-2.0)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; susceptance=-1.5)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; susceptance=-2.5)
# HVDC diagonal A–C (outside KVL)
makenodeinterco("HVDC", a, c, Inf, Inf, snapshot; dc=true)

# Apply KVL, then optimise
applydcopf!(snapshot)
optimize!(snapshot, cost(snapshot))
result_dc = extract(snapshot)

# output

Snapshot with 10 component(s) and 5 node(s)

```

```jldoctest dc_opf_dc
julia> printsnapshot(result_dc, "dc-opf-hvdc.xlsx")
```

That creates `results/dc-opf-hvdc.xlsx`. With the HVDC diagonal, the AC and
DC volume blocks in `Annual values (all)` disagree on purpose (TWh/y):

### Interconnection volume (AC)

| From \\ To | A | B | C | D | Total |
| --- | --- | --- | --- | --- | --- |
| A |  | 0.003 |  | 0.004 | 0.007 |
| B | 0 |  | 0 |  | 0 |
| C |  | 0.007 |  | 0.004 | 0.011 |
| D | 0 |  | 0 |  | 0 |
| Total | 0 | 0.009 | 0 | 0.009 | 0.018 |

### Interconnection volume (DC)

| From \\ To | A | B | C | D | Total |
| --- | --- | --- | --- | --- | --- |
| A |  |  | 0.02 |  | 0.02 |
| B |  |  |  |  | 0 |
| C | 0 |  |  |  | 0 |
| D |  |  |  |  | 0 |
| Total | 0 | 0 | 0.02 | 0 | 0.02 |
