# Two Countries

Two electricity regions trade across a [`makenodeinterco`](@ref) link. Country 1
is CCGT-based with spare cheap capacity. Country 2 is PV- and battery-based,
with an expensive gas peaker for residual hours. Demand and PV availability
come from `time_series.xlsx` (`country1` / `country2` demand columns and
`PV_country2`); technology costs stay as argument-mode teaching values
(`tech_mode=:arguments`, `timeseries_mode=:excel`).

The interconnection moves energy from country 1 to country 2 most of the year;
daytime PV on country 2 can reverse a slice of that flow.

```jldoctest two_countries; output = false
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
    tech_mode=:arguments,
    timeseries_mode=:excel,
)))

country1 = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
country2 = Node("country2", EnergyCarrier("electricity country2", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "country1", country1, snapshot)
makedemand("Demand", "country2", country2, snapshot)

makedispatchable(
    "CCGT", "CCGT", country1, co2, snapshot;
    cap=1500.0,
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

makeintermittentsource(
    "Solar", "PV", country2, co2, snapshot;
    cap=1200.0,
    weatheryear=2019,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=25,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=0.0,
    co2_emission=0.0,
)

makebatterystorage(
    "Battery", "Battery", country2, snapshot;
    capin=400.0,
    eff=0.85,
    duration=4.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=10,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
)

makedispatchable(
    "Gas", "Gas", country2, co2, snapshot;
    cap=1000.0,
    overnight_cost=0.0,
    om_fixed_cost=0.0,
    decommissioning=0.0,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=0.0,
    fuel_cost=90.0,
    co2_emission=0.0,
    unit_size=0.0,
)

makenodeinterco("IC", country1, country2, Inf, Inf, snapshot)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 7 component(s) and 2 node(s)

```

Annual generation already separates the two countries' plants. Country 1's cheap
CCGT runs hard; country 2's free PV and battery discharge cover part of its
load, and expensive gas fills only a residual:

```jldoctest two_countries
julia> balance(result, "CCGT country1", :output, energy; collapse=true, aggregate=true)
1.2296100731717663e7

julia> balance(result, "Solar country2", :output, energy; collapse=true, aggregate=true)
1.6419079848000023e6

julia> balance(result, "Battery country2", :output, energy; collapse=true, aggregate=true)
341063.21818000014

julia> balance(result, "Gas country2", :output, energy; collapse=true, aggregate=true)
1.149265248220001e6
```

A sample week on country 2 makes the trade-off visible. The figure uses hours
4141–4308 (about day 173 of the year), chosen so both import-heavy nights and
daytime reverse export while PV is strong appear in the same week. The top
panel stacks local plants—PV, then battery discharge, then expensive gas—up to
the black demand line and fills any shortfall with imports (steel blue), as in
the price-interconnection example. Local generation that exceeds demand is
shown above the demand line as hatched yellow export (`2->1`). The lower panel
shows the same week's net interconnection flow (`input − input2`):

![Country 2 stacked supply and imports to demand, hatched exports above demand, and net interconnection flow over one week](../assets/two-countries-week.svg)

The annual trade balance is the other half of the story. With
`aggregate=false`, `input` is country1->country2 and `input2` is the reverse;
net export from country 1 is their difference:

```jldoctest two_countries
julia> annual_trade = balance(result, "IC_country1_country2", :input, energy; collapse=true, aggregate=false)
Dict{String, Float64} with 2 entries:
  "input" => 5.87027e6
  "input2" => 13670.5

julia> annual_trade["input"] - annual_trade["input2"]
5.856596189717642e6
```

Country 1's CCGT (1500 MW) covers its own workbook demand and still has spare
capacity to export. Country 2 meets the rest from PV, battery, imports, and
only about `1.15e6 MWh` of expensive gas. The link is what lets country 1's
cheaper plant serve both nodes—and why imports, not gas, usually close the
gap under demand in the figure.

The lower panel of the same week is that trade as a signed series. Positive
values are country1->country2 imports into country 2; negative values are
daytime reverse export while PV is strong.

```jldoctest two_countries
julia> hourly_trade = balance(result, "IC_country1_country2", :input, energy; collapse=false, aggregate=false);

julia> net = hourly_trade["input"] .- hourly_trade["input2"];

julia> maximum(net)
925.445

julia> minimum(net)
-319.08820000000003
```

A finite directional capacity on `makenodeinterco` would multiply each hour by
the corresponding `transfer_capacities` column (`country1>country2` or
`country2>country1`) unless you pass explicit availability multipliers.
