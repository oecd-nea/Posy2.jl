# DC OPF

Four regions form a ring of AC [`makenodeinterco`](@ref) links. Without DC
optimal power flow the ring is a transport network: nodal balance is enough
and many flow patterns can clear the same demands. Turning on DC OPF adds
Kirchhoff's voltage law (KVL) on AC cycles, so the split of flows around the
loop is fixed.

Set `dcopf=true`, give every AC link a negative susceptance, then call
[`applydcopf!`](@ref) once the network is complete and before optimisation.

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

makenodeinterco("IC", a, b, Inf, Inf, snapshot; susceptance=-1.0)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; susceptance=-2.0)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; susceptance=-1.5)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; susceptance=-2.5)

applydcopf!(snapshot)
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 9 component(s) and 4 node(s)

```

This ring has four vertices, four AC edges, and one connected component, so it
has `4 - 4 + 1 = 1` independent loop (`A -> B -> C -> D -> A`).
[`applydcopf!`](@ref) adds a KVL constraint on that loop. A more highly meshed
network would add one constraint for every independent AC cycle.

For a bidirectional node interconnection, `aggregate=false` keeps the two ports
separate (`input` and `input2`). Net flow in the declared direction is
`input - input2`. Under DCOPF those flows are fixed by KVL:

```jldoctest dc_opf
julia> balance(result, "IC_A_B", :input, energy; collapse=true, aggregate=false)
Dict{String, Float64} with 2 entries:
  "input" => 10352.7
  "input2" => 0.0

julia> balance(result, "IC_B_C", :input, energy; collapse=true, aggregate=false)
Dict{String, Float64} with 2 entries:
  "input" => 1592.73
  "input2" => 0.0

julia> balance(result, "IC_C_D", :input, energy; collapse=true, aggregate=false)
Dict{String, Float64} with 2 entries:
  "input" => 0.0
  "input2" => 7167.27

julia> balance(result, "IC_D_A", :input, energy; collapse=true, aggregate=false)
Dict{String, Float64} with 2 entries:
  "input" => 0.0
  "input2" => 15927.3

julia> balance(result, "CCGT A", :output, energy; collapse=true, aggregate=true)
35040.0
```

The plant supplies a flat 4 MW (one megawatt of demand in each zone), or
`35040 MWh` over the year. With DCOPF the split of flows around the routes from
A is unique rather than one of many transport solutions.

Only independent AC cycles receive KVL constraints; a radial network has no
cycle to constrain. Links built with `dc=true` represent controllable DC
interconnectors and are excluded from the AC cycle basis.
