using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Hydrogen components" begin
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
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, h2
    end

    # A valid flat hydrogen purchase input should create and register the component.
    let
        s, h2 = makesnapshot()
        c = makeflathydrogenpurchase("H2 purchase", h2, 8760.0, s)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "H2 purchase H2") === c
        @test Nosy.hastag(c, :function, "purchase")
        @test Nosy.hastag(c, :function, "hydrogen")
    end

    # A negative purchase amount is invalid and fails before construction.
    let
        s, h2 = makesnapshot()
        @test_throws ArgumentError makeflathydrogenpurchase("H2 purchase", h2, -1.0, s)
        @test !Nosy.hascomponent(s, "H2 purchase H2")
    end
end
