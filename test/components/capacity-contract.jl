using Posy2
using Nosy
using Test
using JuMP
using HiGHS

# The shared capacity contract: every capacity argument accepts nothing, a
# number, a JuMP expression or a solved snapshot; a fixed zero keeps the
# component and its port; mincap/maxcap assert against a fixed value.
@testset "Capacity contract" begin
    function contract_snapshot(; hours=2)
        sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1 // 1, hours)))
        set_silent(sim.model)
        snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
            tech_mode=:arguments, timeseries_mode=:arguments,
        )))
        elec = Node("E1", EnergyCarrier("electricity E1", sim);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        h2 = Node("H2", EnergyCarrier("hydrogen", sim); rule=:curtailed, tags=[:hydrogen])
        co2 = Node("CO2", CO2Carrier("carbon", sim); rule=:curtailed, tags=[:co2])
        return snapshot, elec, h2, co2
    end

    fixedcap(c, pname) = only(filter(
        b -> b.data.pname == pname,
        Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior),
    )).data.val

    function second_electricity(s)
        return Node("E2", EnergyCarrier("electricity E2", sim(s));
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
    end

    # A solved snapshot passed as a capacity freezes the fleet, for every builder.
    let
        s, elec, h2, co2 = contract_snapshot()
        makedispatchable("CCGT", elec, co2, s; tech_column="CCGT", cap=nothing, maxcap=40.0, om_var_cost=1.0)
        makeintermittentsource("PV", elec, co2, s; tech_column="PV", cap=nothing, maxcap=30.0, profile=1.0)
        makehydroror("ROR", "Z1", elec, s; cap=nothing, maxcap=20.0, intake=10.0, intake_profile=1.0)
        makebatterystorage("Battery", elec, s; tech_column="Li", power_cap=nothing, power_maxcap=10.0, roundtrip_eff=1.0, duration=4.0)
        makeelectrolyser("Electrolyser", elec, h2, s; tech_column="PEM", cap=nothing, maxcap=5.0, efficiency=1.0)
        makehydrogenstorage("H2 storage", h2, s; tech_column="Cavern", energy_cap=nothing, energy_maxcap=50.0, roundtrip_eff=1.0)
        # reservoir capacities are exogenous, so the source fleet is fixed
        makehydroreservoir("Reservoir", "Z1", elec, s; tech_column="Hydro",
            discharge_cap=15.0, charge_cap=8.0, intake=0.0,
            energy_cap=60.0, roundtrip_eff=1.0)
        makedemand("Load", "Z1", elec, s; profile_multiplier=0.0, annual_flat_demand=100.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, th2, tco2 = contract_snapshot()
        gas = makedispatchable("CCGT", telec, tco2, t; tech_column="CCGT", cap=ini, om_var_cost=1.0)
        pv = makeintermittentsource("PV", telec, tco2, t; tech_column="PV", cap=ini, profile=1.0)
        ror = makehydroror("ROR", "Z1", telec, t; cap=ini, intake=10.0, intake_profile=1.0)
        bat = makebatterystorage("Battery", telec, t; tech_column="Li", power_cap=ini, roundtrip_eff=1.0, duration=4.0)
        elyser = makeelectrolyser("Electrolyser", telec, th2, t; tech_column="PEM", cap=ini, efficiency=1.0)
        h2store = makehydrogenstorage("H2 storage", th2, t; tech_column="Cavern", energy_cap=ini, roundtrip_eff=1.0)
        res = makehydroreservoir("Reservoir", "Z1", telec, t; tech_column="Hydro",
            discharge_cap=ini, charge_cap=ini, intake=0.0, energy_cap=ini, roundtrip_eff=1.0)

        @test fixedcap(gas, "output") ≈ capacity(ini, "CCGT E1")
        @test fixedcap(pv, "output") ≈ capacity(ini, "PV E1")
        @test fixedcap(ror, "output") ≈ capacity(ini, "ROR E1")
        @test fixedcap(bat, "input") ≈ capacity(ini, "Battery E1")
        @test fixedcap(elyser, "input") ≈ capacity(ini, "Electrolyser E1")
        @test fixedcap(h2store, "level") ≈ capacity(ini, "H2 storage H2")
        # the reservoir inherits each of its three capacities from the same component
        source = Nosy.getcomponent(ini, "Reservoir E1")
        @test fixedcap(res, "output") ≈ capacity(source, "output")
        @test fixedcap(res, "input") ≈ capacity(source, "input")
        @test fixedcap(res, "level") ≈ capacity(source, "level")
    end

    # An extracted snapshot holding no matching component: used below so that the
    # missing-component path is reached rather than the unextracted-source one.
    function extracted_without_components()
        e, eelec, _, eco2 = contract_snapshot()
        makedispatchable("Other", eelec, eco2, e; tech_column="CCGT", cap=100.0, om_var_cost=1.0)
        makedemand("Load", "Z1", eelec, e; profile_multiplier=0.0, annual_flat_demand=8760.0)
        Nosy.optimize!(e, cost(e))
        return extract(e)
    end

    # A snapshot without the named component is an error, not a silent zero.
    let
        s, elec, h2, co2 = contract_snapshot()
        empty_ini = extracted_without_components()
        @test empty_ini isa Snapshot{Float64}
        @test_throws "`cap` was given a snapshot with no component named \"CCGT E1\" to inherit port \"output\" from" makedispatchable("CCGT", elec, co2, s; tech_column="CCGT", cap=empty_ini)
        # each message names the port the builder would have inherited from
        @test_throws "no component named \"EPR E1\" to inherit port \"output\"" makenuclear(
            "EPR", elec, co2, s; tech_column="Nuclear", cap=empty_ini)
        @test_throws "no component named \"PV E1\" to inherit port \"output\"" makeintermittentsource(
            "PV", elec, co2, s; tech_column="PV", cap=empty_ini, profile=1.0)
        @test_throws "no component named \"Battery E1\" to inherit port \"input\"" makebatterystorage(
            "Battery", elec, s; tech_column="Li", power_cap=empty_ini, roundtrip_eff=1.0, duration=4.0)
        @test_throws "no component named \"Electrolyser E1\" to inherit port \"input\"" makeelectrolyser(
            "Electrolyser", elec, h2, s; tech_column="PEM", cap=empty_ini, efficiency=1.0)
        @test_throws "no component named \"H2 storage H2\" to inherit port \"level\"" makehydrogenstorage(
            "H2 storage", h2, s; tech_column="Cavern", energy_cap=empty_ini, roundtrip_eff=1.0)
        @test_throws "`discharge_cap` was given a snapshot with no component named \"Reservoir E1\" to inherit port \"output\" from" makehydroreservoir(
            "Reservoir", "Z1", elec, s; tech_column="Hydro",
            discharge_cap=empty_ini, charge_cap=0.0, intake=0.0, roundtrip_eff=1.0)
    end

    # Inheriting reads solved values, so an unextracted source is rejected.
    let
        s, elec, _, co2 = contract_snapshot()
        makedispatchable("CCGT", elec, co2, s; tech_column="CCGT",
            cap=100.0, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        makedemand("Load", "Z1", elec, s; profile_multiplier=0.0, annual_flat_demand=8760.0 * 60.0)
        Nosy.optimize!(s, cost(s))
        # optimized but never extracted: capacities are still JuMP expressions
        @test s isa Snapshot{JuMP.AffExpr}

        t, telec, _, tco2 = contract_snapshot()
        @test_throws "`cap` was given a snapshot that is not extracted" makedispatchable(
            "CCGT", telec, tco2, t; tech_column="CCGT", cap=s)
        @test_throws "component \"CCGT E1\" port \"output\" is still a JuMP expression" makedispatchable(
            "CCGT", telec, tco2, t; tech_column="CCGT", cap=s)
        @test_throws "`uc` was given a snapshot that is not extracted" makedispatchable(
            "CCGT", telec, tco2, t; tech_column="CCGT", cap=100.0, uc=s, unit_size=50.0)
    end

    # A same-named source component of another kind lacks the requested port.
    let
        s, elec, _, co2 = contract_snapshot()
        makedispatchable("Twin", elec, co2, s; tech_column="CCGT", cap=100.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, _, _ = contract_snapshot()
        # "Twin E1" exists but is a generator: it has no "input" port to inherit
        @test_throws "component \"Twin E1\" has no port named \"input\"" makebatterystorage(
            "Twin", telec, t; tech_column="Li", power_cap=ini, roundtrip_eff=1.0, duration=4.0)
    end

    # A commitment schedule can be replayed, but only against a fixed capacity.
    let
        s, elec, _, co2 = contract_snapshot(hours=24)
        makedispatchable("CCGT", elec, co2, s; tech_column="CCGT",
            cap=100.0, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        makedemand("Load", "Z1", elec, s; profile_multiplier=0.0, annual_flat_demand=8760.0 * 60.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, _, tco2 = contract_snapshot(hours=24)
        replayed = makedispatchable("CCGT", telec, tco2, t; tech_column="CCGT",
            cap=ini, uc=ini, unit_size=50.0, om_var_cost=1.0)
        @test !isempty(Nosy.getbehaviors(replayed, Nosy.FleetUnitCommitmentFromIniBehavior))
        @test fixedcap(replayed, "output") ≈ capacity(ini, "CCGT E1")

        # the same fleet with commitment re-optimized: a plain UC behavior
        u, uelec, _, uco2 = contract_snapshot(hours=24)
        fresh = makedispatchable("CCGT", uelec, uco2, u; tech_column="CCGT",
            cap=ini, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        @test isempty(Nosy.getbehaviors(fresh, Nosy.FleetUnitCommitmentFromIniBehavior))
        @test !isempty(Nosy.getbehaviors(fresh, Nosy.FleetUnitCommitmentBehavior))

        # a replayed schedule counts units of the source fleet
        v, velec, _, vco2 = contract_snapshot(hours=24)
        @test_throws "requires a fixed capacity" makedispatchable("CCGT", velec, vco2, v; tech_column="CCGT",
            cap=nothing, uc=ini, unit_size=50.0)
        # and the source component must carry one
        w, welec, _, wco2 = contract_snapshot(hours=24)
        noc = extracted_without_components()
        @test_throws "`uc` was given a snapshot with no component named \"CCGT E1\"" makedispatchable(
            "CCGT", welec, wco2, w; tech_column="CCGT", cap=10.0, uc=noc, unit_size=50.0)
        # a source component that exists but was solved without unit commitment
        x, xelec, _, xco2 = contract_snapshot(hours=24)
        y, yelec, _, yco2 = contract_snapshot(hours=24)
        makedispatchable("CCGT", yelec, yco2, y; tech_column="CCGT", cap=100.0, om_var_cost=1.0)
        makedemand("Load", "Z1", yelec, y; profile_multiplier=0.0, annual_flat_demand=8760.0)
        Nosy.optimize!(y, cost(y))
        nouc = extract(y)
        @test_throws "carries no unit commitment behavior on port \"output\"" makedispatchable(
            "CCGT", xelec, xco2, x; tech_column="CCGT", cap=10.0, uc=nouc, unit_size=50.0)
    end

    # Replaying a nuclear schedule never builds fresh refuelling constraints: the
    # source may have no refuelling selector to index into.
    let
        s, elec, _, co2 = contract_snapshot(hours=24)
        makenuclear("EPR", elec, co2, s; tech_column="Nuclear",
            cap=100.0, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        makedemand("Load", "Z1", elec, s; profile_multiplier=0.0, annual_flat_demand=8760.0 * 60.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)
        # the source was solved without refuelling, so it has a single shutdown selector
        @test length(first(Nosy.getbehaviors(
            Nosy.getcomponent(ini, "EPR E1"), Nosy.FleetUnitCommitmentBehavior,
        )).shutdownselector) == 1

        t, telec, _, tco2 = contract_snapshot(hours=24)
        replayed = @test_logs (:warn,) match_mode=:any makenuclear("EPR", telec, tco2, t; tech_column="Nuclear",
            cap=ini, uc=ini, unit_size=50.0, om_var_cost=1.0,
            refuel_fraction_per_year=1.0, refuel_duration=30.0, refuel_slot_spacing=24)
        @test !isempty(Nosy.getbehaviors(replayed, Nosy.FleetUnitCommitmentFromIniBehavior))
    end

    # A fixed zero keeps the component and its port everywhere.
    let
        s, elec, h2, co2 = contract_snapshot()
        gas = makedispatchable("CCGT", elec, co2, s; tech_column="CCGT", cap=0.0)
        ror = makehydroror("ROR", "Z1", elec, s; cap=0.0, intake=0.0)
        res = makehydroreservoir("Reservoir", "Z1", elec, s; tech_column="Hydro",
            discharge_cap=10.0, charge_cap=0.0, intake=0.0, roundtrip_eff=1.0)
        @test !isnothing(gas)
        @test Nosy.getcomponent(s, "CCGT E1") === gas
        @test fixedcap(gas, "output") == 0.0
        @test fixedcap(ror, "output") == 0.0
        # 2.7: charging and intake both zero used to reduce over an empty collection
        @test Nosy.hasport(res, "input")
        @test fixedcap(res, "input") == 0.0
    end

    # Bounds are assertions against a fixed or inherited capacity.
    let
        s, elec, _, co2 = contract_snapshot()
        @test !isnothing(makedispatchable("In range", elec, co2, s; tech_column="CCGT",
            cap=50.0, mincap=10.0, maxcap=100.0))
        @test_throws ArgumentError makedispatchable("Below", elec, co2, s; tech_column="CCGT",
            cap=5.0, mincap=10.0)
        @test_throws ArgumentError makedispatchable("Above", elec, co2, s; tech_column="CCGT",
            cap=500.0, maxcap=100.0)
    end

    # Node interconnections expose the same capacity contract on one capacity
    # shared by both directional ports.
    let
        s, elec, _, _ = contract_snapshot()
        other = second_electricity(s)
        maketransmissionlink("Line", elec, other, s; cap=nothing, maxcap=40.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, _, _ = contract_snapshot()
        tother = second_electricity(t)
        inherited = maketransmissionlink("Line", telec, tother, t; cap=ini)
        source = Nosy.getcomponent(ini, "Line_E1_E2")
        @test fixedcap(inherited, "input") ≈ capacity(source, "input")
        @test fixedcap(inherited, "input2") ≈ capacity(source, "input")
    end

    let
        s, elec, _, _ = contract_snapshot()
        other = second_electricity(s)
        disabled = maketransmissionlink("Disabled", elec, other, s; cap=0.0)
        @test fixedcap(disabled, "input") == 0.0
        @test fixedcap(disabled, "input2") == 0.0
    end

    let
        s, elec, _, _ = contract_snapshot()
        other = second_electricity(s)
        @test_throws ArgumentError maketransmissionlink(
            "Below", elec, other, s; cap=5.0, mincap=10.0,
        )
    end

    let
        s, elec, _, _ = contract_snapshot()
        other = second_electricity(s)
        @test_throws ArgumentError maketransmissionlink(
            "Above", elec, other, s; cap=50.0, maxcap=10.0,
        )
    end

    let
        s, elec, _, _ = contract_snapshot()
        other = second_electricity(s)
        empty_ini = extracted_without_components()
        @test_throws "no component named \"Line_E1_E2\" to inherit port \"input\"" maketransmissionlink(
            "Line", elec, other, s; cap=empty_ini,
        )
    end

    # Price links expose the same contract on two independent directional
    # capacities, each inheriting from the port that carries it.
    let
        s, elec, _, _ = contract_snapshot()
        makepricelink("Market", elec, s;
            import_capacity=nothing, import_maxcap=40.0,
            export_capacity=nothing, export_maxcap=25.0,
            spot_price=1.0, import_availability=1.0, export_availability=1.0)
        makedemand("Load", "Z1", elec, s; profile_multiplier=0.0, annual_flat_demand=100.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, _, _ = contract_snapshot()
        inherited = makepricelink("Market", telec, t;
            import_capacity=ini, export_capacity=ini,
            spot_price=1.0, import_availability=1.0, export_availability=1.0)
        source = Nosy.getcomponent(ini, "Market_E1")
        @test fixedcap(inherited, "output") ≈ capacity(source, "output")
        @test fixedcap(inherited, "input") ≈ capacity(source, "input")
    end

    # A fixed zero disables a direction without dropping its port, and two zeros
    # build the whole corridor without resolving any series.
    let
        s, elec, _, _ = contract_snapshot()
        disabled = makepricelink("Disabled", elec, s;
            import_capacity=0.0, export_capacity=0.0)
        @test fixedcap(disabled, "output") == 0.0
        @test fixedcap(disabled, "input") == 0.0
    end

    # Each direction is bounded by its own mincap/maxcap, named in the message.
    let
        s, elec, _, _ = contract_snapshot()
        @test_throws "below `import_mincap`" makepricelink("Below", elec, s;
            import_capacity=5.0, import_mincap=10.0, export_capacity=0.0,
            spot_price=1.0, import_availability=1.0)
        @test_throws "above `export_maxcap`" makepricelink("Above", elec, s;
            import_capacity=0.0, export_capacity=50.0, export_maxcap=10.0,
            spot_price=1.0, export_availability=1.0)
    end

    let
        s, elec, _, _ = contract_snapshot()
        empty_ini = extracted_without_components()
        @test_throws "no component named \"Market_E1\" to inherit port \"output\"" makepricelink(
            "Market", elec, s; import_capacity=empty_ini, export_capacity=0.0,
            spot_price=1.0, import_availability=1.0,
        )
    end
end
