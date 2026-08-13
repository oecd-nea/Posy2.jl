using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Conversion components" begin
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
        heat = Node("HEAT", EnergyCarrier("heat", sim), rule=:curtailed, tags=[:heat])
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, elec, heat, h2
    end

    # Electrolyser should fail when gridlosses is outside [0, 1).
    let
        s, elec, _, h2 = makesnapshot()
        @test_throws ArgumentError makeelectrolyser("EL", "PEM", elec, h2, s; gridlosses=1.0)
    end

    # Electrolyser capacity inputs reject non-real numeric values at the API boundary.
    let
        s, elec, _, h2 = makesnapshot()
        @test_throws TypeError makeelectrolyser("EL", "PEM", elec, h2, s; cap=1 + im)
    end

    # A valid electrolyser input should create and register the component.
    let
        s, elec, _, h2 = makesnapshot()
        c = makeelectrolyser(
            "EL", "PEM", elec, h2, s;
            cap=100.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0,
            decommissioning=0.1, lifetime=30.0, construction_profile=1.0, decommissioning_profile=1.0,
            om_var_cost=1.0,
        )
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "EL ZONE1") === c
    end
end
