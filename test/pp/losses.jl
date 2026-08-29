using Posy2
using Nosy
using Test
using JuMP
using HiGHS
using DataFrames

@testset "Post processing losses" begin
    function tsim()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        return sim
    end

    function posyopts()
        return Dict(
            :posy => Posy2Options(
                data_dir=joinpath(dirname(@__DIR__), "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
                tech_mode=:excel,
                timeseries_mode=:excel,
                discountrate=0.05,
                co2_price=50.0,
            ),
        )
    end

    # two-zone snapshot; `nodelosses` applies to ZONE1 only
    function makesnapshot(; nodelosses=0.0)
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=nodelosses, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec1, elec2, co2
    end

    function argument_snapshot(; hours=nothing)
        mesh = isnothing(hours) ? TimeMesh() : TimeMesh(fill(1 // 1, hours))
        sim = Sim(Model(HiGHS.Optimizer); mesh=mesh)
        set_silent(sim.model)
        snap = Snapshot(sim, Dict(:posy => Posy2Options(
            tech_mode=:arguments,
            timeseries_mode=:arguments,
        )))
        elec = Node(
            "grid", EnergyCarrier("electricity grid", sim);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        co2 = Node("CO2", CO2Carrier("CO2", sim); rule=:curtailed, tags=[:co2])
        return snap, elec, co2
    end

    # A lossless system reports no rows at all, and the aggregates stay well defined.
    let
        snap, elec1, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test isempty(Posy2.losses(s))
        @test names(Posy2.losses(s)) == ["node", "source", "tech", "category", "losses"]
        @test isempty(Posy2.losses(s; by=:node))
        @test sum(Posy2.losses(s).losses; init=0.0) == 0.0
        @test sum(Posy2.losses(s; collapse=false).losses; init=zeros(Nosy.nhours(sim(s)))) == zeros(Nosy.nhours(sim(s)))
    end

    # Component grid losses: one `:component` row per source, attributed to its electricity node.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0, gridlosses=0.05)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        @test nrow(df) == 1
        row = only(eachrow(df))
        @test row.node == "ZONE1"
        @test row.source == "Other consumption ZONE1"
        @test row.tech == "Other consumption"
        @test row.category == :component
        # 100 MW demand with 5% grid losses
        @test isapprox(row.losses, 0.05 * 100.0 * Nosy.nhours(sim(s)); rtol=1e-12)
        # hourly shape sums back to the collapsed value
        hourly = only(Posy2.losses(s; collapse=false).losses)
        @test length(hourly) == Nosy.nhours(sim(s))
        @test isapprox(sum(hourly), row.losses; rtol=1e-9)
    end

    # Node losses come from the node inflow ratio and match the Nosy node loss port.
    let
        snap, elec1, _, co2 = makesnapshot(nodelosses=0.02)
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        @test df.category == [:node]
        @test df.node == ["ZONE1"] && df.source == ["ZONE1"] && df.tech == ["network"]
        # Nosy keys the node loss output by node name
        port = balance(Nosy.getnode(s, "ZONE1"), :output, energy, collapse=true, aggregate=false)["ZONE1"]
        @test isapprox(only(df.losses), port; rtol=1e-9)
        @test isapprox(sum(only(Posy2.losses(s; collapse=false).losses)), port; rtol=1e-9)
    end

    # An internal interconnection splits its loss between both endpoints: the system
    # total is counted once, while grouping by source recovers the whole corridor.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; lossfactor=0.05)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        ic = df[df.source .== "IC_ZONE1_ZONE2", :]
        @test nrow(ic) == 2
        @test sort(ic.node) == ["ZONE1", "ZONE2"]
        @test all(ic.category .== :interconnection)
        @test all(ic.tech .== "AC")
        @test isapprox(ic.losses[1], ic.losses[2]; rtol=1e-12)

        corridor = Nosy.balance(s, "IC_ZONE1_ZONE2", :output, energy, collapse=true, aggregate=false)["grid losses ic"]
        @test corridor > 0
        @test isapprox(sum(ic.losses), corridor; rtol=1e-12) # counted once in total
        bysource = Posy2.losses(s; by=:source)
        @test isapprox(only(bysource.losses[bysource.source .== "IC_ZONE1_ZONE2"]), corridor; rtol=1e-12)
        @test isapprox(sum(Posy2.losses(s).losses; init=0.0), corridor; rtol=1e-12)
    end

    # Storage charging losses are `input * (1 - eff)` and are not network losses.
    let
        snap, elec1, _, co2 = makesnapshot()
        nh = Nosy.nhours(sim(snap))
        makedemand("Other consumption", "ZONE1", elec1, snap; profile=[h % 24 < 12 ? 50.0 : 150.0 for h in 1:nh])
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=120.0, construction_profile=1.0, decommissioning_profile=1.0)
        makebatterystorage(
            "Battery", "Battery", elec1, snap;
            cap=100.0, eff=0.9, duration=4.0,
            overnight_cost=0.0, om_fixed_cost=0.0, decommissioning=0.0, lifetime=20.0,
            construction_profile=1.0, decommissioning_profile=1.0, connection_cost=0.0, om_var_cost=0.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        @test df.category == [:storage]
        @test df.tech == ["Battery"]
        charged = Nosy.balance(s, "Battery ZONE1", :input, energy, collapse=true, aggregate=false)["input"]
        @test charged > 0
        @test isapprox(only(df.losses), charged * 0.1; rtol=1e-9)
        # storage losses never appear in the nodal balance
        @test sum(Posy2.losses(s; categories=Posy2.NETWORKLOSSES).losses; init=0.0) == 0.0
        # what enters and never leaves the battery is exactly the reported loss
        discharged = Nosy.balance(s, "Battery ZONE1", :output, energy, collapse=true, aggregate=false)["output"]
        @test isapprox(charged - discharged, only(df.losses); rtol=1e-6)
    end

    # Flexible EV: charging and self-discharge losses close the component balance.
    let
        snap, elec, co2 = argument_snapshot()
        makeEV(
            "EV", elec, snap;
            number_ev=100_000.0,
            initial_connected_share=1.0,
            fixed_profile=false, smart_charging=true,
            charging_eff=0.9, self_discharge=0.001,
            departures=repeat([zeros(7); 75_000.0; zeros(16)], 365),
            arrivals=repeat([zeros(7); 75_000.0; zeros(16)], 365),
            departure_soc=0.8, arrival_soc=0.0,
            battery_capacity_per_ev=0.05, max_charging_power_per_ev=0.01,
        )
        makedispatchable("Supply", "unused", elec, co2, snap; cap=300.0, fuel_cost=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        @test sort(df.category) == [:selfdischarge, :storage]
        @test all(df.source .== "EV ZONE1") || all(df.source .== "EV grid")
        input = Nosy.balance(s, only(unique(df.source)), :input, energy, collapse=true, aggregate=false)["input"]
        driving = Nosy.balance(s, only(unique(df.source)), :output, energy, collapse=true, aggregate=false)["driving"]
        sdloss = only(df.losses[df.category .== :selfdischarge])
        @test sdloss > 0
        # charging conversion loss
        @test isapprox(only(df.losses[df.category .== :storage]), input * 0.1; rtol=1e-9)
        # over a cyclic year the stored energy that never drives is self-discharged
        @test isapprox(input * 0.9 - driving, sdloss; rtol=1e-6)
        # everything drawn and not delivered is accounted for
        @test isapprox(input - driving, sum(df.losses); rtol=1e-6)
    end

    # Self-discharge is evaluated on the native step grid, so a mesh whose steps
    # are longer than an hour neither throws nor drifts from the level equation.
    let
        sd = 0.1
        eff = 0.8
        mesh = TimeMesh([2 // 1, 2 // 1]) # 4 hours over 2 steps
        _sim = Sim(Model(HiGHS.Optimizer); mesh=mesh)
        set_silent(_sim.model)
        snap = Snapshot(_sim, Dict(:posy => Posy2Options(tech_mode=:arguments, timeseries_mode=:arguments)))
        elec = Node("grid", EnergyCarrier("electricity grid", _sim); rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", _sim); rule=:curtailed, tags=[:co2])

        # hand-built: the EV builders assume a 24-hour-shaped horizon
        c = Component(
            "Store grid",
            LazyStorage(elec.carrier, eff=Dict("input" => eff, "output" => 1.0), self_discharge=sd, simplified=true),
            Any[
                FreeJointFlow("input", elec.carrier, :input),
                FreeJointFlow("output", elec.carrier, :output),
                FixedCapacity("input", energy, 100.0),
                FixedCapacity("output", energy, 100.0),
                FixedCapacity("level", energy, 200.0),
            ],
        )
        tag!(c, :tech, "Store")
        tag!(c, :zone, elec.name)
        tag!(c, :function, "storage")
        connect!(snap, c, elec)
        makedemand("Load", "grid", elec, snap; profile=[10.0, 10.0, 60.0, 60.0])
        makedispatchable("Supply", "unused", elec, co2, snap; cap=55.0, fuel_cost=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        sdloss = only(df.losses[df.category .== :selfdischarge])
        @test sdloss > 0
        # exactly what the level equation removes: level * (1 - (1 - sd)^Δt) per step
        stored = Nosy._balance(Nosy.getcomponent(s, "Store grid"), :level, energy, collapse=false, aggregate=true)
        @test isapprox(sdloss, sum(parent(stored) .* (1 - (1 - sd)^2)); rtol=1e-12)
        # the hourly shape is on the hour grid and still sums to the same total
        hdf = Posy2.losses(s; collapse=false)
        hourly = only(hdf.losses[hdf.category .== :selfdischarge])
        @test length(hourly) == Nosy.nhours(sim(s)) == 4
        @test isapprox(sum(hourly), sdloss; rtol=1e-12)
        # component energy identity: what is charged and never discharged is lost
        input = Nosy.balance(s, "Store grid", :input, energy, collapse=true, aggregate=false)["input"]
        output = Nosy.balance(s, "Store grid", :output, energy, collapse=true, aggregate=false)["output"]
        @test isapprox(input * eff - output, sdloss; rtol=1e-9)
        @test isapprox(only(df.losses[df.category .== :storage]), input * (1 - eff); rtol=1e-9)
    end

    # lossesby groups on any column combination, keeps hourly series, and honours `categories`.
    let
        snap, elec1, elec2, co2 = makesnapshot(nodelosses=0.02)
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0, gridlosses=0.05)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; lossfactor=0.05)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.losses(s)
        total = sum(df.losses)
        for cols in ((:node,), (:tech,), (:category,), (:node, :category))
            g = Posy2.losses(s; by=cols)
            @test names(g) == [string.(cols)..., "losses"]
            @test isapprox(sum(g.losses), total; rtol=1e-12)
        end
        bynode = Posy2.losses(s; by=:node)
        @test sort(bynode.node) == ["ZONE1", "ZONE2"]
        @test isapprox(
            only(bynode.losses[bynode.node .== "ZONE1"]),
            sum(df.losses[df.node .== "ZONE1"]);
            rtol=1e-12,
        )

        # hourly grouping sums to the collapsed grouping
        hg = Posy2.losses(s; by=:node, collapse=false)
        @test all(length(v) == Nosy.nhours(sim(s)) for v in hg.losses)
        @test isapprox(sum(sum.(hg.losses)), total; rtol=1e-9)

        # restricting the categories only keeps the requested ones
        ics = Posy2.losses(s; categories=(:interconnection,))
        @test all(ics.category .== :interconnection)
        @test isapprox(sum(Posy2.losses(s; categories=(:interconnection,)).losses), sum(ics.losses); rtol=1e-12)
        @test sum(Posy2.losses(s).losses; init=0.0) > sum(Posy2.losses(s; categories=(:interconnection,)).losses)
        @test_throws ArgumentError Posy2.losses(s; by=())
    end

    # gentimeseries: per-source network loss columns sum to the "Total losses" column.
    let
        snap, elec1, elec2, co2 = makesnapshot(nodelosses=0.02)
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0, gridlosses=0.05)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; lossfactor=0.05)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        cols = filter(n -> startswith(n, "losses "), names(df))
        @test sort(cols) == ["losses IC_ZONE1_ZONE2", "losses Other consumption ZONE1", "losses ZONE1"]
        @test isapprox(df[!, "Total losses"], sum(df[!, c] for c in cols); rtol=1e-9)
        @test isapprox(
            sum(df[!, "Total losses"]) * 1000.0,
            sum(Posy2.losses(s; categories=Posy2.NETWORKLOSSES).losses; init=0.0);
            rtol=1e-6,
        )
    end

    # The annual "Grid losses" column reports network losses per node, storage excluded.
    let
        snap, elec1, elec2, co2 = makesnapshot(nodelosses=0.02)
        nh = Nosy.nhours(sim(snap))
        makedemand("Other consumption", "ZONE1", elec1, snap; profile=[h % 24 < 12 ? 50.0 : 150.0 for h in 1:nh], gridlosses=0.05)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=120.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makebatterystorage(
            "Battery", "Battery", elec1, snap;
            cap=100.0, eff=0.9, duration=4.0,
            overnight_cost=0.0, om_fixed_cost=0.0, decommissioning=0.0, lifetime=20.0,
            construction_profile=1.0, decommissioning_profile=1.0, connection_cost=0.0, om_var_cost=0.0,
        )
        # ZONE1 peak needs more than its CCGT plus the corridor, so the battery must cycle
        makenodeinterco("IC", elec1, elec2, 10.0, 10.0, snap; lossfactor=0.05)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_demand_prod(s; showforeign=true)
        net = Posy2.losses(s; by=:node, categories=Posy2.NETWORKLOSSES)
        for zone in ("ZONE1", "ZONE2")
            row = first(line.d[line.d.zone .== zone, :])
            @test isapprox(row["Grid losses"], only(net.losses[net.node .== zone]) / 1e6; rtol=1e-12)
        end
        # the storage row exists but is not part of "Grid losses"
        @test :storage in Posy2.losses(s).category
        @test isapprox(
            first(line.d[line.d.zone .== "Total", "Grid losses"]) * 1e6,
            sum(Posy2.losses(s; categories=Posy2.NETWORKLOSSES).losses; init=0.0);
            rtol=1e-9,
        )
        @test sum(Posy2.losses(s).losses; init=0.0) > sum(Posy2.losses(s; categories=Posy2.NETWORKLOSSES).losses; init=0.0)
    end

    # The loss report pivots by category and by technology, and lists every row.
    let
        snap, elec1, elec2, co2 = makesnapshot(nodelosses=0.02)
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0, gridlosses=0.05)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; lossfactor=0.05)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        bycat, bytech, detail = Posy2.genlosses(s)
        total = sum(Posy2.losses(s).losses) / 1e6
        @test bycat.title == "Losses by category" && bycat.unit == "TWh/y"
        @test names(bycat.d) == ["zone", "grid (component)", "grid (interconnection)", "grid (node)", "Total"]
        @test bycat.d.zone == ["ZONE1", "ZONE2", "Total"]
        @test isapprox(first(bycat.d[bycat.d.zone .== "Total", "Total"]), total; rtol=1e-12)
        @test names(bytech.d) == ["zone", "AC", "Other consumption", "network", "Total"]
        @test isapprox(first(bytech.d[bytech.d.zone .== "Total", "Total"]), total; rtol=1e-12)
        @test names(detail.d) == ["zone", "source", "technology", "category", "losses"]
        @test nrow(detail.d) == nrow(Posy2.losses(s))
        @test isapprox(sum(detail.d.losses), total; rtol=1e-12)
        # the detail table uses the same labels as the pivot
        @test sort(unique(detail.d.category)) == ["grid (component)", "grid (interconnection)", "grid (node)"]

        # the `grid (...)` columns are exactly the annual "Grid losses" column
        gridcols = filter(startswith("grid ("), names(bycat.d))
        @test length(gridcols) == 3
        annual = Posy2._dataline_demand_prod(s; showforeign=true)
        for zone in ("ZONE1", "ZONE2", "Total")
            pivotrow = first(bycat.d[bycat.d.zone .== zone, :])
            annualrow = first(annual.d[annual.d.zone .== zone, :])
            @test isapprox(sum(pivotrow[c] for c in gridcols), annualrow["Grid losses"]; rtol=1e-9)
        end
    end
end
