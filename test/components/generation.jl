using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Generation components" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        opts = Dict(
            :posy => POSY2Options(
                data_dir=joinpath(dirname(@__DIR__), "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
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

    # A valid intermittent source input should create and register the component.
    let
        s, elec, co2 = makesnapshot()
        c = makeintermittentsource("Onwind gen", "Onwind", elec, co2, s; cap=100.0, weatheryear=2019, construction_profile=1.0, decommissioning_profile=1.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Onwind gen ZONE1") === c
    end

    # unit_size=0 skips ramping behaviors even when ramp rates are provided.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT no ramp", "CCGT", elec, co2, s;
            cap=100.0, unit_size=0.0, ramp_up=0.5, ramp_down=0.5,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test !isnothing(c)
        @test isempty(Nosy.getbehaviors(c, Nosy.RampingBehavior))
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
