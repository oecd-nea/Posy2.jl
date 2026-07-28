# Two Countries

Two electricity regions trade across a [`makenodeinterco`](@ref) link. Country A
has cheap CCGT capacity; country B has expensive Oil and a larger demand. The
model exports from A until B's residual is met locally.

POSY2 divides annual demand arguments by 8760, so `load * 8760` builds a flat
`load` MW profile on the default yearly mesh.

```jldoctest two_countries; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
)))

a = Node("A", EnergyCarrier("electricity A", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
b = Node("B", EnergyCarrier("electricity B", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "A", a, snapshot; coeff=0.0, yearlyconstant=40 * 8760)
makedemand("Demand", "B", b, snapshot; coeff=0.0, yearlyconstant=80 * 8760)

makedispatchable(
    "CCGT", "CCGT", a, co2, snapshot;
    cap=100.0,
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
makedispatchable(
    "Oil", "Oil", b, co2, snapshot;
    cap=30.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=68.24,
    co2_emission=0.0,
    unit_size=0.0,
)

makenodeinterco("IC", a, b, Inf, Inf, snapshot)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 5 component(s) and 2 node(s)

```

Demand is flat, so annual energies already show the trade:

```jldoctest two_countries
julia> balance(result, "CCGT A", :output, energy; collapse=true, aggregate=true)
876000.0

julia> balance(result, "IC_A_B", :input, energy; collapse=true, aggregate=true)
525600.0

julia> balance(result, "Oil B", :output, energy; collapse=true, aggregate=true)
175200.0
```

A demands 40 MW and can generate 100 MW of cheaper CCGT, so it keeps 40 MW and
exports 60 MW (`525600 MWh` over the year). B demands 80 MW, imports that
60 MW, and runs only 20 MW of expensive Oil locally. The link is what makes
the cheaper plant serve both nodes. A finite directional capacity on
`makenodeinterco` would multiply each hour by the corresponding
`transfer_capacities` column (`A>B` or `B>A`).
