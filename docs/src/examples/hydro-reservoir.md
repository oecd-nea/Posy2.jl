# Hydro Reservoir

A reservoir plant stores natural inflow and releases it through a turbine. It
does not consume grid electricity, so its charging capacity is zero. This is
POSY2's natural-inflow reservoir pattern.

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

electricity = Node(
    "country1",
    EnergyCarrier("electricity country1", sim),
    rule=:curtailed,
    tags=[:electricity],
)
co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

makedemand(
    "Demand", "unused", electricity, snapshot;
    coeff=0.0,
    yearlyconstant=50.0 * 8760,
)

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

# A costed backup plant supplies demand not covered by annual inflow.
makedispatchable(
    "Backup", "CCGT", electricity, co2, snapshot;
    cap=100.0,
    # Keep capacity continuous for this teaching example.
    unit_size=0.0,
)

optimize!(snapshot, cost(snapshot))
result = extract(snapshot)

# output

Snapshot with 3 component(s) and 2 node(s)

```

```jldoctest hydro_reservoir
julia> round(balance(result, "Reservoir hydro country1", :output, energy; collapse=true, aggregate=true), digits=6)
350400.0

julia> round(balance(result, "Backup country1", :output, energy; collapse=true, aggregate=true), digits=6)
87600.0
```

Annual natural inflow supplies an average 40 MW, and backup generation supplies
the remaining 10 MW. With `inflow=nothing`, POSY2 instead uses the workbook
values as absolute hourly inflows. `intake_mult` can scale either form. The
reservoir energy capacity must be large enough to shift inflow between its
arrival and the chosen turbine dispatch.
