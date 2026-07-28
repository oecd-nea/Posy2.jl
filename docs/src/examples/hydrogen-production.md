# Hydrogen Production

[`makeelectrolyser`](@ref) links an electricity node to a hydrogen node in the
same country. Flat electricity and hydrogen demands set the loads; a CCGT
supplies the power system. The electrolyser is both an electricity consumer
and a hydrogen producer.

Technology assumptions come from `tech_data.xlsx`; demands stay explicit
(`tech_mode=:excel` with `timeseries_mode=:arguments`).

```jldoctest hydrogen_production; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(POSY2), "data")
snapshot = Snapshot(sim, Dict(:posy => POSY2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="unused.xlsx",
    tech_mode=:excel,
    timeseries_mode=:arguments,
)))

electricity = Node("COUNTRY", EnergyCarrier("electricity COUNTRY", sim), rule=:curtailed, tags=[:electricity])
hydrogen = Node("H2 COUNTRY", EnergyCarrier("hydrogen COUNTRY", sim), tags=[:hydrogen])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# 60 MW of ordinary electricity demand and 28 MW-equivalent of hydrogen.
makedemand("Electricity demand", "COUNTRY", electricity, snapshot; coeff=0.0, yearlyconstant=60.0 * 8760)
makeflathydrogendemand("Hydrogen demand", hydrogen, 28.0 * 8760, snapshot)

# The PEM efficiency and all cost assumptions are read from tech_data.xlsx.
makeelectrolyser("Electrolyser", "PEM", electricity, hydrogen, snapshot; maxcap=100.0)
makedispatchable("Gas", "CCGT", electricity, co2, snapshot; maxcap=200.0, unit_size=0.0)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 3 node(s)

```

Annual energies close the conversion first. The electrolyser draws `elec` from
the power system and delivers `h2` to the hydrogen node; their ratio is the
workbook's 58% PEM efficiency. Capacity is rated on the electricity **input**,
so the build-out follows from that load:

```jldoctest hydrogen_production
julia> elec = balance(result, "Electrolyser COUNTRY", :input, energy; collapse=true, aggregate=true);

julia> h2 = balance(result, "Electrolyser COUNTRY", :output, energy; collapse=true, aggregate=true);

julia> elec
422896.551724186

julia> h2
245280.0

julia> round(h2 / elec; digits=2)
0.58

julia> table(result, capacity)
1×4 DataFrame
 Row │ Electricity demand COUNTRY  Electrolyser COUNTRY  Gas COUNTRY  Hydrogen ⋯
     │ Float64                     Float64               Float64      Float64  ⋯
─────┼──────────────────────────────────────────────────────────────────────────
   1 │                        0.0               48.2759      108.276           ⋯
                                                                1 column omitted
```

About `elec / 8760` MW of electrolyser plus the 60 MW ordinary demand sets the
108.276 MW gas plant. The page's point is that conversion: electricity in,
hydrogen out, capacity on the input side.

## Alternative supply option

When hydrogen is bought rather than produced, replace the electrolyser with
[`makeflathydrogenpurchase`](@ref). That builder fills the hydrogen node only;
it does not draw electricity and adds no cost to the objective. Attach an
explicit Nosy cost behaviour if purchases should enter `cost(snapshot)`.

```julia
# Instead of makeelectrolyser(...):
makeflathydrogenpurchase("Hydrogen purchase", hydrogen, 28.0 * 8760, snapshot)
```

See [Hydrogen](../components/hydrogen.md) for the purchase builder API.
