# Coarse Time Mesh

The [Two Countries](two-countries.md) system solved twice: once on the default
hourly mesh, once on 4380 two-hour steps. The data, the capacities, and the
components are identical, and only the mesh changes.

Posy2 fixes the horizon at a full non-leap year, but not the number of steps
inside it. The model carries one set of variables per step, so aggregating
steps is the main lever on model size. It is not a free approximation: Nosy
attaches values to step boundaries, so a two-hour mesh reads the first hour of
each pair and never the second.

This example measures both sides of that trade on a system where the answer is
known at hourly resolution.

```jldoctest coarse_mesh; output = false
using Posy2
using Nosy
using HiGHS
import JuMP: set_silent, num_variables

# The Two Countries system, with the time mesh left as an argument
function two_countries(mesh)
    sim = Sim(Model(HiGHS.Optimizer); mesh=mesh)
    set_silent(model(sim))
    example_data_dir = joinpath(pkgdir(Posy2), "data")
    snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
        data_dir=example_data_dir,
        techdata_file="tech_data.xlsx",
        timeseries_file="time_series.xlsx",
        tech_mode=:arguments,
        timeseries_mode=:excel,
    )))

    country1 = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
    country2 = Node("country2", EnergyCarrier("electricity country2", sim), rule=:curtailed, tags=[:electricity])
    co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

    makedemand("Demand", "country1", country1, snapshot)
    makedemand("Demand", "country2", country2, snapshot)
    makedispatchable("CCGT", country1, co2, snapshot; cap=1500.0, fuel_cost=47.06)
    makeintermittentsource("Solar", country2, co2, snapshot; tech_column="PV", cap=1200.0, weather_year=2019)
    makebatterystorage("Battery", country2, snapshot; power_cap=400.0, roundtrip_eff=0.85, duration=4.0)
    makedispatchable("Gas", country2, co2, snapshot; tech_column="Gas", cap=1000.0, fuel_cost=90.0)
    maketransmissionlink("IC", country1, country2, snapshot; cap=10_000.0, atob_availability=1.0, btoa_availability=1.0)

    return sim, snapshot
end

# Hourly reference: 8760 steps of one hour
sim_hourly, snapshot_hourly = two_countries(TimeMesh())
optimize!(snapshot_hourly, cost(snapshot_hourly))
result_hourly = extract(snapshot_hourly)

# Same study on 4380 steps of two hours
sim_2h, snapshot_2h = two_countries(TimeMesh(fill(2 // 1, 4380)))
optimize!(snapshot_2h, cost(snapshot_2h))
result_2h = extract(snapshot_2h)

# output

Snapshot with 7 component(s) and 2 node(s)

```

The weight vector is what defines the mesh. `fill(2 // 1, 4380)` gives 4380
steps of two hours each; the weights are rational, and their sum must be the
8760 hours Posy2 requires:

```jldoctest coarse_mesh
julia> TimeMesh(fill(2 // 1, 4380))
Time mesh (8760 hours, 4380 steps, circular)
```

## Model Size

Halving the number of steps halves the model. Every flow, storage level, and
balance is written per step, so the variable count follows the step count
exactly:

```jldoctest coarse_mesh
julia> num_variables(model(sim_hourly))
61320

julia> num_variables(model(sim_2h))
30660
```

The constraint count halves the same way, from 26280 to 13140. Solve time is
not guaranteed to follow, but on this LP it did: HiGHS took about half as long
on the two-hour model as on the hourly one.

## What A Two-Hour Step Samples

The inputs are still hourly vectors of 8760 values. What changes is how many
of them the model reads. Country 2's demand loses about 0.1% of its annual
energy:

```jldoctest coarse_mesh
julia> balance(result_hourly, "Demand country2", :input, energy; collapse=true, aggregate=true)
8.587581795999995e6

julia> balance(result_2h, "Demand country2", :input, energy; collapse=true, aggregate=true)
8.579178634000001e6
```

That second number is exactly twice the sum of the demand profile over the
first hour of each two-hour block: each sampled hour is counted for the whole
of its step, and the hour in between is dropped. The size of the error is set
by the shape of the series, not by the mesh. A flat series would come through
unchanged; a profile with a sharp peak on a dropped hour would lose it
entirely.

## Dispatch And Cost

The demand error propagates into dispatch, but not evenly. Country 1's CCGT
runs near base load and barely moves, while country 2's gas peaker absorbs
most of the difference because it is the residual technology:

```jldoctest coarse_mesh
julia> balance(result_hourly, "CCGT country1", :output, energy; collapse=true, aggregate=true)
1.2296100731717668e7

julia> balance(result_2h, "CCGT country1", :output, energy; collapse=true, aggregate=true)
1.229838532008234e7

julia> balance(result_hourly, "Gas country2", :output, energy; collapse=true, aggregate=true)
1.149265248220001e6

julia> balance(result_2h, "Gas country2", :output, energy; collapse=true, aggregate=true)
1.1332518947100018e6
```

The CCGT moves by 0.02% and the gas peaker by 1.4%. A 0.1% error on demand
becomes a percent-level error on the technology that covers the last slice of
it, which is often the technology the study is about.

The same shift shows up in total system cost:

```jldoctest coarse_mesh
julia> cost(result_hourly)
6.820883727744321e8

julia> cost(result_2h)
6.80754683686975e8
```

The two-hour model is 0.2% cheaper, about twice the demand error: it is asked
to serve slightly less energy, and slightly more of what remains comes from
country 1's cheap CCGT instead of country 2's peaker. A cost difference between
two meshes measures the meshes, not the systems.

Report shapes are unaffected by the mesh. Hourly series are interpolated back
onto the 8760-hour grid, so `collapse=false` queries and [`printsnapshot`](@ref)
return 8760 values whatever the step length:

```jldoctest coarse_mesh
julia> length(balance(result_2h, "Gas country2", :output, energy; collapse=false, aggregate=true))
8760
```