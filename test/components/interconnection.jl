using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Interconnection components" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer))
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
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        return snap, elec1, elec2
    end

    # With atob/btoa set to Inf, node interconnection should be creatable without transfer capacity series.
    let
        s, elec1, elec2 = makesnapshot()
        c = makenodeinterco("IC", elec1, elec2, Inf, Inf, s)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "IC_ZONE1_ZONE2") === c
    end

    # Price interconnection should fail when required spot/transfer series are missing.
    let
        s, elec1, _ = makesnapshot()
        @test_throws ArgumentError makepriceinterco("ZONE2", elec1, 100.0, 100.0, s)
    end
end
