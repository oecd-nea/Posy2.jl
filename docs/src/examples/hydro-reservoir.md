# Hydro Reservoir

A reservoir plant stores natural inflow and releases it through a turbine. It
does not consume grid electricity, so its charging capacity is zero. Demand
and a costed CCGT complete the system so the optimiser can decide when to use
stored water. The default `TimeMesh()` is circular, so the reservoir level
wraps from the last hour into the first. Year-end and year-start are continuous.

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
        tech_mode=:excel,
        timeseries_mode=:excel,
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

julia> balance(result, "Reservoir hydro country1", :input, energy; collapse=true, aggregate=false)["natural"]
350399.9999999993
```

Annual natural inflow equals annual turbine output here: both the `natural`
and `output` ports have unit efficiency. The builder's configurable `eff`
applies only to grid pumping through the `input` port, which is unused here
because charging capacity is zero. That inflow is the `40 * 8760` MWh passed
to the builder. That is 40 MW on average against 50 MW flat demand, so the CCGT
covers the remaining 10 MW.

The reservoir's job is to shift that inflow in time. In many hours the turbine
matches the 50 MW demand. When natural inflow is above that, `level` rises
(water is stored). When inflow is below it, `level` falls (stored water is
released). Over four weeks the stock fills, then draws down:

![Natural inflow, turbine output, and reservoir level over four weeks](../assets/hydro-reservoir-timing.svg)

The same pattern shows up hour by hour. Around hour 2817 inflow sits above the
turbine, so `level` climbs:

```jldoctest hydro_reservoir
julia> inflow = balance(result, "Reservoir hydro country1", :input, energy; collapse=false, aggregate=false)["natural"];

julia> output = balance(result, "Reservoir hydro country1", :output, energy; collapse=false, aggregate=true);

julia> level = balance(result, "Reservoir hydro country1", :level, energy; collapse=false, aggregate=true);

julia> inflow[2817:2827]
11-element Vector{Float64}:
 51.656726282562985
 51.520981662145495
 51.36273371039652
 51.49341178915265
 51.76241668104175
 51.63244410736087
 51.46247770895529
 51.35683071485551
 51.305919585316694
 51.50213974766442
 51.31774323241728

julia> output[2817:2827]
11-element Vector{Float64}:
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0

julia> level[2817:2827]
11-element Vector{Float64}:
 146.75729891587133
 148.41402519843433
 149.93500686057982
 151.29774057097634
 152.791152360129
 154.55356904117073
 156.1860131485316
 157.64849085748688
 159.00532157234238
 160.31124115765908
 161.8133809053235
```

Later, around hour 3441, inflow is below the turbine and `level` falls:

```jldoctest hydro_reservoir
julia> inflow[3441:3451]
11-element Vector{Float64}:
 49.10793728288946
 48.891055900480794
 48.89491962587727
 48.88311437046271
 49.013942525376656
 48.48960585664394
 48.61969687278271
 48.686443979641524
 48.887068582954335
 48.8005128945979
 48.93274617432283

julia> output[3441:3451]
11-element Vector{Float64}:
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0
 50.0

julia> level[3441:3451]
11-element Vector{Float64}:
 197.51865627869137
 196.62659356158082
 195.51764946206163
 194.4125690879389
 193.29568345840158
 192.30962598377823
 190.79923184042218
 189.41892871320488
 188.1053726928464
 186.99244127580073
 185.79295417039862
```

The plant is therefore both a generator and a reservoir: energy arrives with
the inflow profile and is dispatched when it displaces the CCGT. With
`inflow=nothing`, POSY2 uses the workbook values as absolute hourly inflows
instead of scaling a normalised shape. `intake_mult` can scale either form.
The reservoir energy capacity must be large enough for that shift between
arrival and dispatch.
