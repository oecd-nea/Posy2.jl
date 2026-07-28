using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Storage components" begin
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
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, elec, h2
    end

    # Battery duration should fail when it is zero.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makebatterystorage(
            "Battery", "Battery", elec, s;
            eff=0.9, duration=0.0,
            overnight_cost=1000.0, lifetime=20, construction_profile=1.0, decommissioning_profile=1.0,
        )
    end

    # A valid battery input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makebatterystorage(
            "Battery", "Battery", elec, s;
            capin=100.0,
            eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Battery ZONE1") === c
    end

    # Hydrogen storage should fail when efficiency is outside (0, 1].
    let
        s, _, h2 = makesnapshot()
        @test_throws ArgumentError makehydrogenstorage("H2 Storage", "Hydrogen storage", h2, s; eff=1.2)
    end

    # A valid hydro reservoir input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makehydroreservoir(
            "Hydro reservoir", "Battery", "ZONE1", elec, 100.0, 50.0, 500.0, 0.0, s;
            gridlosses=0.0, eff=0.9,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=1.0,
            decommissioning=0.1, lifetime=30.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Hydro reservoir ZONE1") === c
    end
end
