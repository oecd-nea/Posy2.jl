# Hydrogen Production

[`makeelectrolyser`](@ref) links an electricity node to a hydrogen node. This
example feeds the electrolyser from workbook PV rather than a gas plant: daytime
solar produces hydrogen, and [`makehydrogenstorage`](@ref) shifts it across
hours so a shaped hydrogen demand stays met. There is no electricity-side
battery; flexibility sits on the hydrogen node. The H2ㄴ demand uses the
`country1` column of the workbook `demand` sheet, scaled so its mean is 28 MW
(about `28 * 8760` MWh/year). Storage level capacity is about one week of that
mean load (`28 * 168` MWh).

PEM and PV assumptions come from `tech_data.xlsx`. The PV profile is
`PV_country1` in `profiles_2019`. Hydrogen storage is not in the workbook, so
its efficiency and costs are set in the builder call.

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
    timeseries_file="time_series.xlsx",
    tech_mode=:excel,
    timeseries_mode=:excel,
)))

electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
hydrogen = Node("H2 country1", EnergyCarrier("hydrogen country1", sim), tags=[:hydrogen])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Workbook demand shape, scaled to a 28 MW mean hydrogen load.
coeff = (28.0 * 8760) / sum(gettimeseries(snapshot, "country1", "demand"; digits=6))
makedemand("Hydrogen demand", "country1", hydrogen, snapshot; coeff=coeff)

makeintermittentsource("Solar", "PV", electricity, co2, snapshot; maxcap=1000.0, weatheryear=2019)
makeelectrolyser("Electrolyser", "PEM", electricity, hydrogen, snapshot; maxcap=300.0)
makehydrogenstorage(
    "H2 storage", "Hydrogen storage", hydrogen, snapshot;
    cap=28.0 * 168,   # about one week of the mean hydrogen demand
    eff=1.0,
    overnight_cost=50.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 2 node(s)

```

The electrolyser still closes the conversion: electricity in, hydrogen out, at
the workbook's 58% PEM efficiency. Capacity is rated on the electricity
**input**:

```jldoctest hydrogen_production
julia> elec = balance(result, "Electrolyser country1", :input, energy; collapse=true, aggregate=true);

julia> h2 = balance(result, "Electrolyser country1", :output, energy; collapse=true, aggregate=true);

julia> elec
422896.5517241434

julia> h2
245279.99999999718

julia> h2 / elec
0.5799999999999859

julia> table(result, capacity)[:, ["Electrolyser country1", "H2 storage H2 country1", "Solar country1"]]
1×3 DataFrame
 Row │ Electrolyser country1  H2 storage H2 country1  Solar country1
     │ Float64                Float64                 Float64
─────┼───────────────────────────────────────────────────────────────
   1 │               217.856                  4704.0         754.032
```

PV is oversized relative to mean electrolyser load so winter weeks stay
feasible with only about a week of hydrogen stock. Over two lower-solar weeks,
hourly H2 demand is met by electrolyser output plus H2 from storage
(`demand ≈ electrolyser + from storage` when the electrolyser runs below
demand). Production stays below demand overall, so the storage level trends
down:

![Hydrogen demand, electrolyser output, storage supply, and storage level over two weeks](../assets/hydrogen-production-week.svg)

## Alternative supply option

When H2 is bought rather than produced, replace the electrolyser (and the PV
and storage that support it) with [`makeflathydrogenpurchase`](@ref). That
builder fills the H2 node only; it does not draw electricity and adds no cost
to the objective. Attach an explicit Nosy cost behaviour if purchases should
enter `cost(snapshot)`.

```julia
# Instead of makeelectrolyser / makeintermittentsource / makehydrogenstorage:
makeflathydrogenpurchase("Hydrogen purchase", hydrogen, 28.0 * 8760, snapshot)
```

See [Hydrogen](../components/hydrogen.md) for the purchase builder API.
