# Hydro Reservoir

A reservoir plant stores natural inflow and releases it through a turbine. It
does not consume grid electricity, so its charging capacity is zero. Demand
and a costed CCGT complete the system so the optimiser can decide when to use
stored water.

The example uses both illustrative workbooks: `time_series.xlsx` provides the
`country1` shape in `reservoir_inflow_2019`, while `tech_data.xlsx` provides
the `Hydro res` and `CCGT` assumptions. Passing a numeric `inflow` makes
[`makehydroreservoir`](@ref) normalise that profile and scale it to the stated
annual energy.

```jldoctest hydro_reservoir; output = false
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(sim))
example_data_dir = joinpath(pkgdir(POSY2), "data")
snapshot = Snapshot(
    sim,
    Dict(:posy => POSY2Options(
        data_dir=example_data_dir,
        techdata_file="tech_data.xlsx",
        timeseries_file="time_series.xlsx",
    )),
)

electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand("Demand", "country1", electricity, snapshot; coeff=0.0, yearlyconstant=50.0 * 8760)

makehydroreservoir(
    "Reservoir hydro",
    "Hydro res",
    "country1",
    electricity,
    100.0,        # turbine capacity (MW)
    0.0,          # no pumping from the electricity grid
    40.0 * 8760,  # reservoir energy capacity (MWh)
    40.0 * 8760,  # annual natural inflow (MWh)
    snapshot;
    renormalize=true,
    weatheryear=2019,
    simplified=true,
)

# CCGT supplies demand not covered by annual inflow.
makedispatchable("CCGT", "CCGT", electricity, co2, snapshot; cap=100.0, unit_size=0.0)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 2 node(s)

```

```jldoctest hydro_reservoir
julia> balance(result, "Reservoir hydro country1", :output, energy; collapse=true, aggregate=true)
350399.9999999997

julia> balance(result, "CCGT country1", :output, energy; collapse=true, aggregate=true)
87599.99999999999
```

Natural inflow averages 40 MW across the year against 50 MW flat demand, so
hydro supplies most of the energy and the CCGT covers the remaining 10 MW.
That split alone does not show *when* water is stored. The reservoir `level`
rises when inflow is banked and falls when the turbine runs;
`argmax(level)` marks the yearly peak:

```jldoctest hydro_reservoir
julia> level = balance(result, "Reservoir hydro country1", :level, energy; collapse=false, aggregate=true);

julia> peak = argmax(level)
3030

julia> level[peak-5:peak+5]
11-element Vector{Float64}:
 350.8957793077647
 351.6887452066525
 352.31057573157216
 352.8037806898941
 352.8737252717765
 352.89728528588023
 352.72501871971684
 352.70518538985425
 352.4995246715731
 352.2040632358564
 351.75298533082463

julia> maximum(level)
352.89728528588023
```

The plant is therefore both a generator and a reservoir: energy arrives with
the inflow profile and is dispatched when it displaces the CCGT. With
`inflow=nothing`, POSY2 uses the workbook values as absolute hourly inflows
instead of scaling a normalised shape. `intake_mult` can scale either form.
The reservoir energy capacity must be large enough for that shift between
arrival and dispatch.
