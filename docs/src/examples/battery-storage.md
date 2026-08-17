# Battery Storage

Flat demand with variable PV leaves evenings short of solar.
With a battery [`makebatterystorage`](@ref) shifts daytime surplus forward on
the same electricity node so less OCGT generation is needed in the evening.
An OCGT plant covers hours the battery cannot reach. Capacities are fixed.

```jldoctest battery_storage; output = false
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
    tech_mode=:arguments,
    timeseries_mode=:excel,
)))

# Electricity node and CO2 sink
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Flat 50 MW demand so evenings short of solar come from the PV shape alone
makedemand("Demand", "country1", electricity, snapshot; coeff=0.0, yearlyconstant=50.0 * 8760)

# Fixed 100 MW PV
makeintermittentsource(
    "Solar", "PV", electricity, co2, snapshot;
    cap=100.0,
    weatheryear=2019,
    om_var_cost=15.0,
)

# Fixed battery: 50 MW charge rating, 85% round-trip, 4 h energy duration
makebatterystorage(
    "Battery", "Battery", electricity, snapshot;
    cap=50.0,
    eff=0.85,
    duration=4.0,
)

# Fixed 50 MW OCGT backup for hours storage cannot cover
makedispatchable(
    "OCGT", "OCGT", electricity, co2, snapshot;
    cap=50.0,
    fuel_cost=68.24,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 1 node(s)

```

Annual battery charge (`:input`) and discharge (`:output`) recover the stated
85% round-trip efficiency. The gap is storage loss. OCGT still covers most of the
year because the battery only shifts a slice of the daytime surplus.

```jldoctest battery_storage
julia> charge = balance(result, "Battery country1", :input, energy; collapse=true, aggregate=true)
12021.6263

julia> discharge = balance(result, "Battery country1", :output, energy; collapse=true, aggregate=true)
10218.382355000003

julia> discharge / charge
0.8500000000000003
```

Write the solved result with [`printsnapshot`](@ref) to open the workbook report:

```jldoctest battery_storage
julia> printsnapshot(result, "battery-storage.xlsx")
```

On the `Time series` sheet look at the rows where `Hour` is 4065–4077
(GW / GWh). Daytime PV surplus charges the battery and the level rises. After
the level peaks the battery discharges as solar falls. OCGT takes over again
when discharge stops:

| Hour | Solar country1 | charging Battery country1 | level Battery country1 | discharging Battery country1 | OCGT country1 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 4065 | 0.0579648 | 0.0079648 | 0 | 0 | 0 |
| 4066 | 0.0726536 | 0.0226536 | 0.01301282 | 0 | 0 |
| 4067 | 0.0829082 | 0.0329082 | 0.036626585 | 0 | 0 |
| 4068 | 0.0883065 | 0.0383065 | 0.0668928325 | 0 | 0 |
| 4069 | 0.0883065 | 0.0383065 | 0.0994533575 | 0 | 0 |
| 4070 | 0.0829082 | 0.0329082 | 0.129719605 | 0 | 0 |
| 4071 | 0.0712113 | 0.0212113 | 0.1527203925 | 0 | 0 |
| 4072 | 0.0513438 | 0.0013438 | 0.16230631 | 0 | 0 |
| 4073 | 0.0376847 | 0 | 0.162877425 | 0 | 0.0123153 |
| 4074 | 0.0232514 | 0 | 0.1602777575 | 0.005199335 | 0.021549265 |
| 4075 | 0.009247 | 0 | 0.13730159 | 0.040753 | 0 |
| 4076 | 0.0003066 | 0 | 0.09207839 | 0.0496934 | 0 |
| 4077 | 0 | 0 | 0.06723169 | 0 | 0.05 |
