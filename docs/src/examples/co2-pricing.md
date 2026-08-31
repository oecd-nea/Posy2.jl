# CO2 Pricing

A single electricity node is served by three candidate technologies:

- Coal: cheap fuel, 820 kg/MWh
- CCGT: costlier fuel, 348 kg/MWh
- Nuclear: expensive to build, cheap to run, no emissions

`co2_price` in [`Posy2Options`](@ref) is the carbon price every emitting
builder applies by default. Each emitting component links its electricity
output to a CO2 flow of `output * co2_emission / 1000` tonnes and charges the
price on that flow under the `:co2` cost tag. Components declared with
`co2_emission=0` are never connected to the CO2 node and carry no carbon cost.

All three capacities are chosen in the cost minimisation, so the carbon price
changes both what is dispatched and what is built. The study is run twice:
without a carbon price, then at 100 USD/ton.

```jldoctest co2_pricing; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration, without a carbon price
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:arguments,
    timeseries_mode=:excel,
    co2_price=0.0,
)))

# Electricity node and CO2 sink. The node variable is not named `co2`, so that
# Nosy's `co2` modifier stays available for the emission queries below.
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
emissions = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Hourly electricity demand from the time-series workbook
makedemand("Demand", "country1", electricity, snapshot)

# Cheap fuel, high emissions
makedispatchable(
    "Coal", electricity, emissions, snapshot; tech_column="Coal",
    maxcap=2_000.0,
    overnight_cost=1_500.0,
    lifetime=40,
    construction_profile=1.0,
    om_fixed_cost=35.0,
    fuel_cost=25.0,
    co2_emission=820.0,
)

# Costlier fuel, roughly half the emissions
makedispatchable(
    "Gas", electricity, emissions, snapshot; tech_column="CCGT",
    maxcap=2_000.0,
    overnight_cost=955.0,
    lifetime=30,
    construction_profile=1.0,
    om_fixed_cost=26.79,
    fuel_cost=47.06,
    co2_emission=348.0,
)

# Expensive to build, cheap to run, no emissions
makenuclear(
    "Nuclear", electricity, emissions, snapshot; tech_column="Nuclear",
    maxcap=2_000.0,
    overnight_cost=3_370.0,
    lifetime=60,
    construction_profile=1.0,
    om_fixed_cost=79.0,
    fuel_cost=7.0,
    co2_emission=0.0,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 4 component(s) and 2 node(s)

```

Two nodes appear in the snapshot because coal and CCGT emit: the CO2 node is
connected only by components with a non-zero emission factor.

Without a carbon price, nuclear covers the base load, and coal takes the
mid-merit slice ahead of CCGT because its fuel is cheaper:

```jldoctest co2_pricing
julia> table(result, capacity)
1×4 DataFrame
 Row │ Coal country1  Demand country1  Gas country1  Nuclear country1
     │ Float64        Float64          Float64       Float64
─────┼────────────────────────────────────────────────────────────────
   1 │       194.871              0.0       204.522           631.371
```

## Emission Accounting

The CO2 flow of an emitting component is queried like any other balance, using
Nosy's `co2` modifier. Collapsed over the year, it returns tonnes emitted:

```jldoctest co2_pricing
julia> balance(result, "Coal country1", :output, co2; collapse=true, aggregate=true)
707827.9212400212

julia> balance(result, "Gas country1", :output, co2; collapse=true, aggregate=true)
30832.662539999958

julia> balance(result, "Nuclear country1", :output, co2; collapse=true, aggregate=true)
0.0
```

Coal generates about 0.86 TWh against 5.49 TWh of nuclear, yet accounts for
96% of the 739 kt emitted:

```jldoctest co2_pricing
julia> balance(result, "Coal country1", :output, energy; collapse=true, aggregate=true)
863204.7820000256

julia> balance(result, "Nuclear country1", :output, energy; collapse=true, aggregate=true)
5.4877001550002415e6
```

The carbon charge itself is a cost tag, so it is zero here:

```jldoctest co2_pricing
julia> cost(result, :co2)
0.0

julia> cost(result)
2.6848589016233397e8
```

## A Carbon Price Of 100 USD/ton

A carbon price adds `co2_price * co2_emission / 1000` to each emitting plant's
variable cost: 0.820 per tonne of price for coal, 0.348 for CCGT. Coal starts
22.06 per MWh below CCGT on fuel, so the two swap places in the merit order at
a price of about 47 USD/ton. At 100 USD/ton coal is dearer than CCGT by
running cost alone, and its cheap fuel no longer pays for its capital.

Only the `co2_price` option changes; the rest of the study is identical.

```jldoctest co2_pricing; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent

# Simulation and Posy2 input configuration, at 100 USD/ton of CO2
sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(Posy2), "data")
snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
    data_dir=example_data_dir,
    techdata_file="tech_data.xlsx",
    timeseries_file="time_series.xlsx",
    tech_mode=:arguments,
    timeseries_mode=:excel,
    co2_price=100.0,
)))

# Electricity node and CO2 sink
electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
emissions = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

# Hourly electricity demand from the time-series workbook
makedemand("Demand", "country1", electricity, snapshot)

# Cheap fuel, high emissions
makedispatchable(
    "Coal", electricity, emissions, snapshot; tech_column="Coal",
    maxcap=2_000.0,
    overnight_cost=1_500.0,
    lifetime=40,
    construction_profile=1.0,
    om_fixed_cost=35.0,
    fuel_cost=25.0,
    co2_emission=820.0,
)

# Costlier fuel, roughly half the emissions
makedispatchable(
    "Gas", electricity, emissions, snapshot; tech_column="CCGT",
    maxcap=2_000.0,
    overnight_cost=955.0,
    lifetime=30,
    construction_profile=1.0,
    om_fixed_cost=26.79,
    fuel_cost=47.06,
    co2_emission=348.0,
)

# Expensive to build, cheap to run, no emissions
makenuclear(
    "Nuclear", electricity, emissions, snapshot; tech_column="Nuclear",
    maxcap=2_000.0,
    overnight_cost=3_370.0,
    lifetime=60,
    construction_profile=1.0,
    om_fixed_cost=79.0,
    fuel_cost=7.0,
    co2_emission=0.0,
)

# Minimise total system cost and extract solved values
optimize!(snapshot, cost(snapshot))
result_taxed = extract(snapshot)

# output

Snapshot with 4 component(s) and 2 node(s)

```

Coal is no longer built at all. Nuclear absorbs most of the displaced energy,
and CCGT keeps a slightly larger peaking role than before:

```jldoctest co2_pricing
julia> table(result_taxed, capacity)
1×4 DataFrame
 Row │ Coal country1  Demand country1  Gas country1  Nuclear country1
     │ Float64        Float64          Float64       Float64
─────┼────────────────────────────────────────────────────────────────
   1 │           0.0              0.0       235.937           794.827
```

Annual emissions fall from about 739 kt to 51 kt, all of it now from CCGT:

```jldoctest co2_pricing
julia> balance(result_taxed, "Coal country1", :output, co2; collapse=true, aggregate=true)
0.0

julia> balance(result_taxed, "Gas country1", :output, co2; collapse=true, aggregate=true)
51108.57699600004
```

The remaining emissions are charged at 100 USD/ton, which appears as the
`:co2` cost tag and lifts the total system cost:

```jldoctest co2_pricing
julia> cost(result_taxed, :co2)
5.110857699599994e6

julia> cost(result_taxed)
2.8134404546231943e8
```

The carbon charge of 5.11 M is a transfer, not a resource cost. Net of it, the
system spends 276.2 M against 268.5 M without a carbon price: 7.7 M more of
capital and fuel to avoid 688 kt of CO2.

```jldoctest co2_pricing
julia> cost(result_taxed) - cost(result_taxed, :co2) - cost(result)
7.747297600385487e6
```

Emissions and the carbon charge also appear in the standard workbook report:
[`write_results`](@ref) writes an annual `CO2 emissions (t/y)` row and a `co2`
column in the annual cost table.
