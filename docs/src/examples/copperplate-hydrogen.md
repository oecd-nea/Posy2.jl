# Copperplate Country with Hydrogen

Hydrogen adds a second commodity node to the same copperplate country. This
example reads technology assumptions from `tech_data.xlsx` but uses explicit
flat demands, demonstrating `tech_mode=:excel` together with
`timeseries_mode=:arguments`.
[`makeflathydrogendemand`](@ref) creates the hydrogen demand and
[`makeelectrolyser`](@ref) couples it to the electricity system.

```jldoctest copperplate_hydrogen; output = false
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

electricity = Node(
    "COUNTRY",
    EnergyCarrier("electricity COUNTRY", sim),
    rule=:curtailed,
    tags=[:electricity],
)
hydrogen = Node(
    "H2 COUNTRY",
    EnergyCarrier("hydrogen COUNTRY", sim),
    tags=[:hydrogen],
)
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# 60 MW of ordinary electricity demand and 28 MW-equivalent of hydrogen.
makedemand(
    "Electricity demand", "unused", electricity, snapshot;
    coeff=0.0,
    yearlyconstant=60.0 * 8760,
)
makeflathydrogendemand(
    "Hydrogen demand", hydrogen, 28.0 * 8760, snapshot,
)

# The PEM efficiency and all cost assumptions are read from tech_data.xlsx.
makeelectrolyser(
    "Electrolyser", "PEM", electricity, hydrogen, snapshot;
    maxcap=100.0,
)

makedispatchable(
    "Gas", "CCGT", electricity, co2, snapshot;
    maxcap=200.0,
    unit_size=0.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 3 node(s)

```

```jldoctest copperplate_hydrogen
julia> round(capacity(result, "Electrolyser COUNTRY"), digits=6)
48.275862

julia> round(capacity(result, "Gas COUNTRY"), digits=6)
108.275862

julia> balance(result, "Electrolyser COUNTRY", :output, energy; collapse=true, aggregate=true)
245280.0
```

The electrolyser is an electricity demand and a hydrogen producer at the same
time. The workbook's 58% PEM efficiency means 28 MW of hydrogen requires
48.276 MW of electricity. Together with ordinary demand, this explains the
108.276 MW generation capacity. This remains a copperplate approximation for both
commodities: it does not locate the electricity grid, electrolyser, hydrogen
network, or hydrogen consumer inside the country.
