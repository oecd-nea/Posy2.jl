using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Generation components" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        opts = Dict(
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
        snap = Snapshot(sim, opts)
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec, co2
    end

    # cap=0 should skip component creation and return nothing.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT", "CCGT", elec, co2, s;
            cap=0.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test isnothing(c)
        @test !Nosy.hascomponent(s, "CCGT ZONE1")
    end

    # A valid dispatchable input should create and register the component.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable("CCGT", "CCGT", elec, co2, s; cap=100.0, construction_profile=1.0, decommissioning_profile=1.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "CCGT ZONE1") === c
        capacity_behavior = only(Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior))
        workbook_unit_size = gettechparam(s, "CCGT", "unit_size", "dispatchable")
        if iszero(workbook_unit_size)
            @test isnothing(capacity_behavior.data.unitsize)
        else
            @test capacity_behavior.data.unitsize == workbook_unit_size
        end
    end

    # Zero overrides the workbook unit size and is passed to Nosy as nothing.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT continuous", "CCGT", elec, co2, s;
            cap=100.0, unit_size=0.0,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        capacity_behavior = only(Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior))
        @test isnothing(capacity_behavior.data.unitsize)
        @test isempty(Nosy.getbehaviors(c, Nosy.RampingBehavior))
    end

    # If reloading is enabled, a missing reloadmask should be rejected.
    let
        s, elec, co2 = makesnapshot()
        @test_throws ArgumentError makenuclear(
            "Nuclear", "CCGT", elec, co2, s;
            uc=true, cap=100.0,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=2.0,
            decommissioning=0.1, lifetime=30, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, fuel_cost=30.0, waste_cost=0.0,
            no_load_cost=0.0, startup_cost=0.0,
            co2_emission=0.0, unit_size=0.0,
            min_power=0.3, min_uptime=1, min_downtime=1,
            startup_duration=1, shutdown_duration=1,
            reload_fraction_per_year=0.2, reload_duration=12, reloadmask=nothing,
        )
    end

    # Run of river should fail when cap is missing because profile normalization needs cap.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makehydroror("Hydro ROR", "ZONE1", elec, s; cap=nothing)
    end

    # Generation capacity inputs accept real values or nothing, never complex values.
    let
        s, elec, co2 = makesnapshot()
        @test_throws TypeError makenuclear("Nuclear", "CCGT", elec, co2, s; cap=1 + im)
        @test_throws TypeError makeintermittentsource("Wind", "Onwind", elec, co2, s; cap=1 + im)
        @test_throws TypeError makeintermittentsource("Wind", "Onwind", elec, co2, s; mincap=1 + im)
    end

    # A valid intermittent source input should create and register the component.
    let
        s, elec, co2 = makesnapshot()
        c = makeintermittentsource("Onwind gen", "Onwind", elec, co2, s; cap=100.0, weatheryear=2019, construction_profile=1.0, decommissioning_profile=1.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Onwind gen ZONE1") === c
        @test Nosy.hastag(c, :function, "carbonfree")
    end

    # An intermittent source with direct emissions must not be tagged carbon-free.
    let
        s, elec, co2 = makesnapshot()
        c = makeintermittentsource(
            "Emitting intermittent", "Onwind", elec, co2, s;
            cap=100.0, weatheryear=2019, co2_emission=100.0,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test Nosy.hastag(c, :function, "generation")
        @test Nosy.hastag(c, :function, "intermittent")
        @test !Nosy.hastag(c, :function, "carbonfree")
    end

    # A non-zero fractional ramp requires a positive unit size.
    let
        s, elec, co2 = makesnapshot()
        @test_throws ArgumentError makedispatchable(
            "CCGT no ramp", "CCGT", elec, co2, s;
            cap=100.0, unit_size=0.0, ramp_up=0.5, ramp_down=0.5,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
    end

    # ramp_up and ramp_down are scaled by unit_size before passing to Nosy.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT ramp", "CCGT", elec, co2, s;
            cap=8.0, unit_size=2.0, ramp_up=0.2, ramp_down=0.3,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        ramping = Nosy.getbehaviors(c, Nosy.RampingBehavior)
        @test length(ramping) == 2
        up = only(filter(b -> b.data.sense == :up, ramping))
        down = only(filter(b -> b.data.sense == :down, ramping))
        @test up.data.val == 0.2 * 2.0
        @test down.data.val == 0.3 * 2.0
    end
end
