# Two Copperplate Countries

Each country is still a copperplate, but it now has its own electricity node,
demand, generator, and marginal price. [`makenodeinterco`](@ref) transfers
electricity between the two explicitly modelled countries.

The short horizon keeps the network example quick. POSY2's annual-demand
argument is still divided by 8760, so `load * 8760` creates a flat `load` MW
profile on this teaching mesh.

```jldoctest two_countries; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1//1, 24)))
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
)))

function country_node(name)
    Node(
        name,
        EnergyCarrier("electricity $name", sim),
        rule=:curtailed,
        evalprice=true,
        tags=[:electricity],
    )
end

a = country_node("A")
b = country_node("B")
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "unused", a, snapshot; coeff=0.0, yearlyconstant=40 * 8760)
makedemand("Demand", "unused", b, snapshot; coeff=0.0, yearlyconstant=80 * 8760)

function add_gas(node, capacity, fuel_cost)
    makedispatchable(
        "Gas", "unused", node, co2, snapshot;
        cap=capacity,
        overnight_cost=0.0,
        om_fixed_cost=0.0,
        decommissioning=0.0,
        lifetime=30,
        construction_profile=1.0,
        decommissioning_profile=1.0,
        connection_cost=0.0,
        om_var_cost=0.0,
        fuel_cost=fuel_cost,
        co2_emission=0.0,
        unit_size=0.0,
    )
end

add_gas(a, 100.0, 20.0)
add_gas(b, 30.0, 80.0)

# Infinite capacities make this prototype independent of transfer workbooks.
makenodeinterco("IC", a, b, Inf, Inf, snapshot)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 5 component(s) and 2 node(s)

```

```jldoctest two_countries
julia> balance(result, "Gas A", :output, energy; collapse=true, aggregate=true)
2400.0

julia> balance(result, "Gas B", :output, energy; collapse=true, aggregate=true)
480.0

julia> balance(result, "IC_A_B", :input, energy; collapse=true, aggregate=true)
1440.0
```

Country A uses its full 100 MW: 40 MW for itself and 60 MW for export. Country
B generates the remaining 20 MW locally. A finite
directional capacity makes `makenodeinterco` read the corresponding hourly
multiplier—`A>B` or `B>A`—from the `transfer_capacities` sheet.
