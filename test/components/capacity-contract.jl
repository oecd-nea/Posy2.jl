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

    # A solved snapshot passed as a capacity freezes the fleet, for every builder.
    let
        s, elec, h2, co2 = contract_snapshot()
        makedispatchable("CCGT", "CCGT", elec, co2, s; cap=nothing, maxcap=40.0, om_var_cost=1.0)
        makeintermittentsource("PV", "PV", elec, co2, s; cap=nothing, maxcap=30.0, profile=1.0)
        makehydroror("ROR", "Z1", elec, s; cap=nothing, maxcap=20.0, intake=10.0, intake_profile=1.0)
        makebatterystorage("Battery", "Li", elec, s; cap=nothing, maxcap=10.0, eff=1.0, duration=4.0)
        makeelectrolyser("Electrolyser", "PEM", elec, h2, s; cap=nothing, maxcap=5.0, eff=1.0)
        makehydrogenstorage("H2 storage", "Cavern", h2, s; cap=nothing, maxcap=50.0, eff=1.0)
        makehydroreservoir("Reservoir", "Hydro", "Z1", elec, s;
            cap_discharging=nothing, maxcap_discharging=15.0,
            cap_charging=nothing, maxcap_charging=8.0, intake=0.0,
            cap_reservoir=nothing, maxcap_reservoir=60.0, eff=1.0)
        makedemand("Load", "Z1", elec, s; coeff=0.0, yearlyconstant=100.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, th2, tco2 = contract_snapshot()
        gas = makedispatchable("CCGT", "CCGT", telec, tco2, t; cap=ini, om_var_cost=1.0)
        pv = makeintermittentsource("PV", "PV", telec, tco2, t; cap=ini, profile=1.0)
        ror = makehydroror("ROR", "Z1", telec, t; cap=ini, intake=10.0, intake_profile=1.0)
        bat = makebatterystorage("Battery", "Li", telec, t; cap=ini, eff=1.0, duration=4.0)
        elyser = makeelectrolyser("Electrolyser", "PEM", telec, th2, t; cap=ini, eff=1.0)
        h2store = makehydrogenstorage("H2 storage", "Cavern", th2, t; cap=ini, eff=1.0)
        res = makehydroreservoir("Reservoir", "Hydro", "Z1", telec, t;
            cap_discharging=ini, cap_charging=ini, intake=0.0, cap_reservoir=ini, eff=1.0)

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
        makedispatchable("Other", "CCGT", eelec, eco2, e; cap=100.0, om_var_cost=1.0)
        makedemand("Load", "Z1", eelec, e; coeff=0.0, yearlyconstant=8760.0)
        Nosy.optimize!(e, cost(e))
        return extract(e)
    end

    # A snapshot without the named component is an error, not a silent zero.
    let
        s, elec, h2, co2 = contract_snapshot()
        empty_ini = extracted_without_components()
        @test empty_ini isa Snapshot{Float64}
        @test_throws "`cap` was given a snapshot with no component named \"CCGT E1\" to inherit port \"output\" from" makedispatchable("CCGT", "CCGT", elec, co2, s; cap=empty_ini)
        # each message names the port the builder would have inherited from
        @test_throws "no component named \"EPR E1\" to inherit port \"output\"" makenuclear(
            "EPR", "Nuclear", elec, co2, s; cap=empty_ini)
        @test_throws "no component named \"PV E1\" to inherit port \"output\"" makeintermittentsource(
            "PV", "PV", elec, co2, s; cap=empty_ini, profile=1.0)
        @test_throws "no component named \"Battery E1\" to inherit port \"input\"" makebatterystorage(
            "Battery", "Li", elec, s; cap=empty_ini, eff=1.0, duration=4.0)
        @test_throws "no component named \"Electrolyser E1\" to inherit port \"input\"" makeelectrolyser(
            "Electrolyser", "PEM", elec, h2, s; cap=empty_ini, eff=1.0)
        @test_throws "no component named \"H2 storage H2\" to inherit port \"level\"" makehydrogenstorage(
            "H2 storage", "Cavern", h2, s; cap=empty_ini, eff=1.0)
        @test_throws "`cap_discharging` was given a snapshot with no component named \"Reservoir E1\" to inherit port \"output\" from" makehydroreservoir(
            "Reservoir", "Hydro", "Z1", elec, s;
            cap_discharging=empty_ini, cap_charging=0.0, intake=0.0, eff=1.0)
    end

    # Inheriting reads solved values, so an unextracted source is rejected.
    let
        s, elec, _, co2 = contract_snapshot()
        makedispatchable("CCGT", "CCGT", elec, co2, s;
            cap=100.0, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        makedemand("Load", "Z1", elec, s; coeff=0.0, yearlyconstant=8760.0 * 60.0)
        Nosy.optimize!(s, cost(s))
        # optimized but never extracted: capacities are still JuMP expressions
        @test s isa Snapshot{JuMP.AffExpr}

        t, telec, _, tco2 = contract_snapshot()
        @test_throws "`cap` was given a snapshot that is not extracted" makedispatchable(
            "CCGT", "CCGT", telec, tco2, t; cap=s)
        @test_throws "component \"CCGT E1\" port \"output\" is still a JuMP expression" makedispatchable(
            "CCGT", "CCGT", telec, tco2, t; cap=s)
        @test_throws "`uc` was given a snapshot that is not extracted" makedispatchable(
            "CCGT", "CCGT", telec, tco2, t; cap=100.0, uc=s, unit_size=50.0)
    end

    # A same-named source component of another kind lacks the requested port.
    let
        s, elec, _, co2 = contract_snapshot()
        makedispatchable("Twin", "CCGT", elec, co2, s; cap=100.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, _, _ = contract_snapshot()
        # "Twin E1" exists but is a generator: it has no "input" port to inherit
        @test_throws "component \"Twin E1\" has no port named \"input\"" makebatterystorage(
            "Twin", "Li", telec, t; cap=ini, eff=1.0, duration=4.0)
    end

    # A commitment schedule can be replayed, but only against a fixed capacity.
    let
        s, elec, _, co2 = contract_snapshot(hours=24)
        makedispatchable("CCGT", "CCGT", elec, co2, s;
            cap=100.0, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        makedemand("Load", "Z1", elec, s; coeff=0.0, yearlyconstant=8760.0 * 60.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)

        t, telec, _, tco2 = contract_snapshot(hours=24)
        replayed = makedispatchable("CCGT", "CCGT", telec, tco2, t;
            cap=ini, uc=ini, unit_size=50.0, om_var_cost=1.0)
        @test !isempty(Nosy.getbehaviors(replayed, Nosy.FleetUnitCommitmentFromIniBehavior))
        @test fixedcap(replayed, "output") ≈ capacity(ini, "CCGT E1")

        # the same fleet with commitment re-optimized: a plain UC behavior
        u, uelec, _, uco2 = contract_snapshot(hours=24)
        fresh = makedispatchable("CCGT", "CCGT", uelec, uco2, u;
            cap=ini, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        @test isempty(Nosy.getbehaviors(fresh, Nosy.FleetUnitCommitmentFromIniBehavior))
        @test !isempty(Nosy.getbehaviors(fresh, Nosy.FleetUnitCommitmentBehavior))

        # a replayed schedule counts units of the source fleet
        v, velec, _, vco2 = contract_snapshot(hours=24)
        @test_throws "requires a fixed capacity" makedispatchable("CCGT", "CCGT", velec, vco2, v;
            cap=nothing, uc=ini, unit_size=50.0)
        # and the source component must carry one
        w, welec, _, wco2 = contract_snapshot(hours=24)
        noc = extracted_without_components()
        @test_throws "`uc` was given a snapshot with no component named \"CCGT E1\"" makedispatchable(
            "CCGT", "CCGT", welec, wco2, w; cap=10.0, uc=noc, unit_size=50.0)
        # a source component that exists but was solved without unit commitment
        x, xelec, _, xco2 = contract_snapshot(hours=24)
        y, yelec, _, yco2 = contract_snapshot(hours=24)
        makedispatchable("CCGT", "CCGT", yelec, yco2, y; cap=100.0, om_var_cost=1.0)
        makedemand("Load", "Z1", yelec, y; coeff=0.0, yearlyconstant=8760.0)
        Nosy.optimize!(y, cost(y))
        nouc = extract(y)
        @test_throws "carries no unit commitment behavior on port \"output\"" makedispatchable(
            "CCGT", "CCGT", xelec, xco2, x; cap=10.0, uc=nouc, unit_size=50.0)
    end

    # Replaying a nuclear schedule never builds fresh reload constraints: the
    # source may have no reload selector to index into.
    let
        s, elec, _, co2 = contract_snapshot(hours=24)
        makenuclear("EPR", "Nuclear", elec, co2, s;
            cap=100.0, uc=true, unit_size=50.0, min_power=0.5, om_var_cost=1.0)
        makedemand("Load", "Z1", elec, s; coeff=0.0, yearlyconstant=8760.0 * 60.0)
        Nosy.optimize!(s, cost(s))
        ini = extract(s)
        # the source was solved without reloading, so it has a single shutdown selector
        @test length(first(Nosy.getbehaviors(
            Nosy.getcomponent(ini, "EPR E1"), Nosy.FleetUnitCommitmentBehavior,
        )).shutdownselector) == 1

        t, telec, _, tco2 = contract_snapshot(hours=24)
        replayed = @test_logs (:warn,) match_mode=:any makenuclear("EPR", "Nuclear", telec, tco2, t;
            cap=ini, uc=ini, unit_size=50.0, om_var_cost=1.0,
            reload_fraction_per_year=1.0, reload_duration=30.0, reloadmask=24.0)
        @test !isempty(Nosy.getbehaviors(replayed, Nosy.FleetUnitCommitmentFromIniBehavior))
    end

    # A fixed zero keeps the component and its port everywhere.
    let
        s, elec, h2, co2 = contract_snapshot()
        gas = makedispatchable("CCGT", "CCGT", elec, co2, s; cap=0.0)
        ror = makehydroror("ROR", "Z1", elec, s; cap=0.0, intake=0.0)
        res = makehydroreservoir("Reservoir", "Hydro", "Z1", elec, s;
            cap_discharging=10.0, cap_charging=0.0, intake=0.0, eff=1.0)
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
        @test !isnothing(makedispatchable("In range", "CCGT", elec, co2, s;
            cap=50.0, mincap=10.0, maxcap=100.0))
        @test_throws ArgumentError makedispatchable("Below", "CCGT", elec, co2, s;
            cap=5.0, mincap=10.0)
        @test_throws ArgumentError makedispatchable("Above", "CCGT", elec, co2, s;
            cap=500.0, maxcap=100.0)
        @test_throws ArgumentError makehydroreservoir("Reservoir", "Hydro", "Z1", elec, s;
            cap_discharging=10.0, cap_charging=50.0, maxcap_charging=20.0, intake=0.0, eff=1.0)
        # the default unlimited level adds no capacity behavior, but still asserts
        @test_throws ArgumentError makehydroreservoir("Bounded unlimited", "Hydro", "Z1", elec, s;
            cap_discharging=10.0, cap_charging=0.0, intake=0.0, maxcap_reservoir=100.0, eff=1.0)
        @test !isnothing(makehydroreservoir("Unlimited above min", "Hydro", "Z1", elec, s;
            cap_discharging=10.0, cap_charging=0.0, intake=0.0, mincap_reservoir=100.0, eff=1.0))
    end
end
