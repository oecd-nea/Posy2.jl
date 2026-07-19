# Four Copperplate Countries

This example connects four country copperplates in a ring. It uses POSY2's
default transport formulation: every interconnector has an independent flow
decision, subject only to the balances of the two countries it joins.

```jldoctest four_countries; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1//1, 24)))
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    dcopf=false,
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

a, b, c, d = country_node.(string.(('A', 'B', 'C', 'D')))
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

for node in (a, b, c, d)
    makedemand(
        "Demand", "unused", node, snapshot;
        coeff=0.0,
        yearlyconstant=1.0 * 8760,
    )
end

makedispatchable(
    "Generator", "unused", a, co2, snapshot;
    cap=10.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=1.0,
    co2_emission=0.0,
    unit_size=0.0,
)

makenodeinterco("IC", a, b, Inf, Inf, snapshot)
makenodeinterco("IC", b, c, Inf, Inf, snapshot)
makenodeinterco("IC", c, d, Inf, Inf, snapshot)
makenodeinterco("IC", d, a, Inf, Inf, snapshot)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 9 component(s) and 4 node(s)

```

```jldoctest four_countries
julia> balance(result, "Generator A", :output, energy; collapse=true, aggregate=true)
96.0
```

The generator in A supplies the four 1 MW demands for 24 hours. In this meshed
transport model, POSY2 does not require a voltage-angle-compatible split
between the two routes from A to C. Several link-flow patterns can therefore
represent the same least-cost dispatch. That is intentional for a transport
model, but it is not an AC power-flow approximation. The next example keeps
the same ring and adds DC OPF.
