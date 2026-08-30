using Posy2
using Nosy
using Test
using JuMP
using HiGHS

# Builders divide annual quantities by 8760, assemble the fixed EV charging
# shape as 365 days of 24 hours, and normalize intake profiles with an
# unweighted hourly sum, so all of them require a full non-leap year.
@testset "Time horizon" begin
    function horizon_snapshot(mesh)
        sim = Sim(Model(HiGHS.Optimizer); mesh=mesh)
        set_silent(sim.model)
        snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
            tech_mode=:arguments, timeseries_mode=:arguments,
        )))
        elec = Node("Z1", EnergyCarrier("electricity Z1", sim);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        other = Node("Z2", EnergyCarrier("electricity Z2", sim);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        h2 = Node("H2", EnergyCarrier("hydrogen", sim); rule=:curtailed, tags=[:hydrogen])
        co2 = Node("CO2", CO2Carrier("CO2", sim); rule=:curtailed, tags=[:co2])
        return snapshot, elec, other, h2, co2
    end

    # The horizon is checked before any other argument, so every builder rejects
    # a shorter mesh whatever else it is given.
    let
        s, elec, other, h2, co2 = horizon_snapshot(TimeMesh(fill(1 // 1, 24)))
        builders = (
            () -> makedemand("X", "Z1", elec, s),
            () -> makeflathydrogendemand("X", h2, 1.0, s),
            () -> makeflexhydrogendemand("X", h2, 1.0, s),
            () -> makedemandresponse("X", elec, 1.0, 1.0, s),
            () -> makeflathydrogenpurchase("X", h2, 1.0, s),
            () -> makeEV("X", elec, s),
            () -> makedispatchable("X", elec, co2, s),
            () -> makenuclear("X", elec, co2, s),
            () -> makeintermittentsource("X", elec, co2, s),
            () -> makehydroror("X", "Z1", elec, s; intake=0.0),
            () -> makehydroreservoir(
                "X", "Z1", elec, s; discharge_cap=1.0, charge_cap=0.0, intake=0.0),
            () -> makebatterystorage("X", elec, s),
            () -> makehydrogenstorage("X", h2, s),
            () -> makeelectrolyser("X", elec, h2, s),
            () -> makepricelink("X", elec, s),
            () -> maketransmissionlink("X", elec, other, s),
        )
        for build in builders
            @test_throws "full non-leap year of 8760 hours, got 24" build()
        end
    end

    # A leap year is not the modeled year either.
    let
        s, elec, _, _, _ = horizon_snapshot(TimeMesh(fill(1 // 1, 8784)))
        @test_throws "got 8784" makedemand("X", "Z1", elec, s; profile=1.0)
    end

    # Only the number of hours is constrained: steps may be aggregated.
    let
        s, elec, _, _, _ = horizon_snapshot(TimeMesh(fill(2 // 1, 4380)))
        c = makedemand(
            "X", "Z1", elec, s; profile_multiplier=0.0, annual_flat_demand=8760.0)
        @test Nosy.getcomponent(s, "X Z1") === c
    end

    # An intake is a yearly total, so it is normalized against the mesh that
    # integrates it rather than against the hour grid. A shape switching on an
    # odd hour is what tells the two apart: a two-hour mesh never samples hour 7.
    let
        shape = repeat([h in 0:6 ? 0.2 : 1.0 for h in 0:23], 365)
        for mesh in (
            TimeMesh(), TimeMesh(fill(2 // 1, 4380)), TimeMesh(fill(6 // 1, 1460)),
        )
            s, elec, _, _, _ = horizon_snapshot(mesh)
            c = makehydroreservoir(
                "Res", "Z1", elec, s; discharge_cap=1.0, charge_cap=0.0,
                intake=1_000.0, energy_cap=1.0, intake_profile=shape,
                roundtrip_eff=1.0,
            )
            # a fixed flow in an unsolved snapshot is a constant expression
            natural = JuMP.constant(
                Nosy.balance(c, :input, energy; collapse=true, aggregate=false)["natural"],
            )
            @test isapprox(natural, 1_000.0; rtol=1e-9)
        end
    end

    # Nuclear refuelling grids are hour grids mapped onto the mesh, so a mesh
    # that is not hourly opens the same slots over the same year.
    function refuel_slots(mesh, refuel_slot_spacing)
        s, elec, _, _, co2 = horizon_snapshot(mesh)
        c = makenuclear(
            "N", elec, co2, s; uc=true, cap=3000.0, unit_size=1000.0,
            min_power=0.3, min_uptime=1, min_downtime=1,
            startup_duration=1, shutdown_duration=1,
            refuel_fraction_per_year=1.0, refuel_duration=720.0,
            refuel_slot_spacing=refuel_slot_spacing,
        )
        ucb = only(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        openslots(series) = [
            i for i in eachindex(series)
            if series[i] isa GenericAffExpr && !iszero(series[i]) &&
                !is_fixed(first(series[i].terms)[1])
        ]
        return openslots(ucb.startup), openslots(ucb.shutdownselector[2])
    end

    let
        # 730 slots on the hard-coded 12-hour switching grid, 12 refuelling starts.
        hourly = refuel_slots(TimeMesh(), 730)
        @test length.(hourly) == (730, 12)
        @test length.(refuel_slots(TimeMesh(fill(2 // 1, 4380)), 730)) == (730, 12)
        # A sub-hourly mesh is covered to its last step, not only to its 8760th.
        quarterly_startup, _ = refuel_slots(TimeMesh(fill(1 // 4, 35040)), 730)
        @test length(quarterly_startup) == 730
        @test last(quarterly_startup) > 8760

        # A spacing that divides neither the hours nor the steps still leaves
        # every one of its starts open.
        _, coarse_refuel = refuel_slots(TimeMesh(fill(2 // 1, 4380)), 700)
        @test length(coarse_refuel) == 13
    end
end
