using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Interconnection components" begin
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
        @test Nosy.hastag(c, :function, "nodeinterconnection")
        zone1_ics = Nosy.getcomponents(s, "ZONE1"; with=[:function => "interconnection", :function => "nodeinterconnection"])
        @test length(zone1_ics) == 1
        @test haskey(zone1_ics, "IC_ZONE1_ZONE2")
    end

    let
        s, elec1, elec2 = makesnapshot()
        c = makenodeinterco("IC", elec1, elec2, Inf, Inf, s; dc=false, admittance=2.5)
        @test POSY2.ic_admittance(s, "ZONE1", "ZONE2") == 2.5
        @test !haskey(c.tags, :admittance)
        mat, nodelist, node_map = POSY2.getic_admittancematrix(s)
        @test nodelist == ["ZONE1", "ZONE2"]
        @test mat[1, 2] == 2.5
        @test length(node_map) == 1
    end

    # Price interconnection succeeds when zone series exist in the fixture.
    let
        s, elec1, _ = makesnapshot()
        c = makepriceinterco("ZONE2", elec1, 100.0, 100.0, s; transactioncost=1.)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "IC_ZONE2_ZONE1") === c
        @test Nosy.hastag(c, :function, "priceinterconnection")
        @test Nosy.hastag(c, :neighbor, "ZONE2")
        @test get(c.tags, :neighbor, String[]) == ["ZONE2"]
    end

    # Price interconnection fails when spot/transfer columns for the zone are missing.
    let
        s, elec1, _ = makesnapshot()
        @test_throws ArgumentError makepriceinterco("ZONE3", elec1, 100.0, 100.0, s)
    end
end
