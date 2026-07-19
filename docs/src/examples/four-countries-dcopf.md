# Four Countries with DC OPF

DC optimal power flow adds Kirchhoff's voltage law (KVL) to cycles of AC
[`makenodeinterco`](@ref) links. Set `dcopf=true`, provide a negative
susceptance for every AC link, then call [`applydcopf!`](@ref) once after the
network is complete and before optimisation.

```jldoctest four_countries_dcopf; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1//1, 24)))
set_silent(model(sim))
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    dcopf=true,
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

b_ab, b_bc, b_cd, b_da = -1.0, -2.0, -1.5, -2.5
makenodeinterco("IC", a, b, Inf, Inf, snapshot; susceptance=b_ab)
makenodeinterco("IC", b, c, Inf, Inf, snapshot; susceptance=b_bc)
makenodeinterco("IC", c, d, Inf, Inf, snapshot; susceptance=b_cd)
makenodeinterco("IC", d, a, Inf, Inf, snapshot; susceptance=b_da)

# Inspect the independent loops that applydcopf! will constrain.
susceptance_matrix, node_names, _ = POSY2.getic_susceptancematrix(snapshot)
cycle_indices = POSY2.gencycles(susceptance_matrix)
selected_loops = [
    join(node_names[vcat(cycle, first(cycle))], " → ")
    for cycle in cycle_indices
]

applydcopf!(snapshot)
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 9 component(s) and 4 node(s)

```

The algorithm sorts the electricity-node names, builds the undirected AC
graph, and selects a minimal independent cycle basis. Closing each selected
cycle by repeating its first node makes the loop explicit:

```jldoctest four_countries_dcopf
julia> only(selected_loops)
"A → B → C → D → A"
```

This ring has four vertices, four AC edges, and one connected component, so it
has `4 - 4 + 1 = 1` independent loop. A more highly meshed network would show
one entry in `selected_loops` for every loop selected for a KVL constraint.

For a bidirectional node interconnection, net flow in the declared direction
is `input - input2`. The voltage drops around the ring sum to zero:

```jldoctest four_countries_dcopf
julia> function netflow(result, name)
           flows = balance(result, name, :input, energy; collapse=false, aggregate=false)
           flows["input"] - flows["input2"]
       end;

julia> f_ab = netflow(result, "IC_A_B");

julia> f_bc = netflow(result, "IC_B_C");

julia> f_cd = netflow(result, "IC_C_D");

julia> f_da = netflow(result, "IC_D_A");

julia> maximum(abs.(f_ab ./ b_ab .+ f_bc ./ b_bc .+ f_cd ./ b_cd .+ f_da ./ b_da)) < 1e-9
true

julia> balance(result, "Generator A", :output, energy; collapse=true, aggregate=true)
96.0
```

Only independent AC cycles receive KVL constraints; a radial network has no
cycle to constrain. Links built with `dc=true` represent controllable DC
interconnectors and are excluded from the AC cycle basis.
