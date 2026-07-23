# Getting Started

POSY2 is a modelling layer on top of Nosy. A normal workflow creates a Nosy
simulation, stores [`POSY2Options`](@ref) in a snapshot, creates the required
carriers and nodes, calls POSY2 component builders, optimises the resulting
Nosy snapshot, and extracts its solution.

## Requirements

POSY2 currently requires Nosy's `POSY2_refactoring` branch, which is planned
for Nosy v0.3.0, and an LP or MILP solver compatible with
[JuMP](https://jump.dev/JuMP.jl/stable/). The examples in this documentation
use [HiGHS](https://highs.dev/) because it is open source and supports the
linear examples used here. Other
[JuMP-compatible solvers](https://jump.dev/JuMP.jl/stable/installation/#Supported-solvers)
can be used the same way. Please note: some solvers require a separate installation and licence.

Use a Julia environment in which POSY2, Nosy, and the selected solver are
already available.

## Minimal Workflow

The following model has a flat 100 MW electricity demand and one dispatchable
plant with optimisable capacity. The example below supplies every builder
argument explicitly (`tech_mode=:arguments` and `timeseries_mode=:arguments`),
so no Excel workbook is read.

```julia
using POSY2
using Nosy
using HiGHS
import JuMP: set_silent

# Create the Nosy simulation and silence solver output.
s = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
set_silent(model(s))

# POSY2 options are stored under the :posy key of the snapshot.
options = POSY2Options(
    data_dir=joinpath(pwd(), "data"),
    techdata_file="unused.xlsx",
    timeseries_file="unused.xlsx",
    tech_mode=:arguments,
    timeseries_mode=:arguments,
    discountrate=0.05,
    co2_price=0.0,
    dcopf=false,
)
snapshot = Snapshot(s, Dict(:posy => options))

# Create the carriers and nodes used by the component builders.
power = EnergyCarrier("electricity", s)
carbon = CO2Carrier("CO2", s)

grid = Node("grid", power; rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
atmosphere = Node("CO2", carbon; rule=:curtailed, tags=[:co2])

# Add a flat 100 MW demand: 100 MW × 8760 hours.
makedemand("Load", "unused", grid, snapshot; coeff=0.0, shift=0, yearlyconstant=876_000.0, gridlosses=0.0)

# Add a dispatchable generator with optimisable capacity.
makedispatchable(
    "Plant",
    "unused",
    grid,
    atmosphere,
    snapshot;
    cap=nothing,
    mincap=0.0,
    maxcap=200.0,
    ini=nothing,
    capacitymultiplier=nothing,
    integeruc=false,
    uc=false,
    fuelnode=nothing,
    co2price=0.0,
    overnight_cost=1_000.0,
    om_fixed_cost=10.0,
    decommissioning=0.1,
    lifetime=30,
    construction_profile=1.0,
    decommissioning_profile=1.0,
    connection_cost=0.0,
    om_var_cost=2.0,
    fuel_cost=50.0,
    no_load_cost=0.0,
    startup_cost=0.0,
    co2_emission=0.0,
    efficiency=1.0,
    unit_size=0.0,
    ramp_up=0.0,
    ramp_down=0.0,
    min_power=0.0,
    min_uptime=0.0,
    min_downtime=0.0,
    startup_duration=0.0,
    shutdown_duration=0.0,
)

# This is a no-op because dcopf=false, but keeps the workflow uniform.
applydcopf!(snapshot)

# Minimise total system cost and extract numeric results.
Nosy.optimize!(snapshot, cost(snapshot))
result = extract(snapshot)
```

The component name combines the builder's name prefix and the node name.
The solved capacity and annual generation are therefore:

```julia
capacity(result, "Plant grid")
# 100.0

balance(result, "Plant grid", :output, energy; collapse=true, aggregate=true)
# 876000.0
```

The original `snapshot` contains JuMP variables and expressions. The extracted
`result` has the same structure, but is populated with optimal values when the
optimisation succeeds.

## Inspecting Results

Nosy's normal metrics work directly on POSY2 snapshots:

```julia
# Total annual system cost.
cost(result)

# Cost breakdown by component and cost tag.
costs(result)

# Component capacities.
table(result, capacity)

# Hourly plant output.
balance(result, "Plant grid", :output, energy; collapse=false, aggregate=true)

# Electricity marginal prices, because evalprice=true on the node.
dualprice(result.nodes["grid"])
```

To use Excel instead, set the workbook filenames, switch `tech_mode` /
`timeseries_mode` to `:excel`, and leave each workbook-backed keyword as
`nothing`. Values you pass explicitly still override Excel. Sheet and column
details are in [Input Workbooks](concepts/input-data.md).
