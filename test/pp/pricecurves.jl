using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing pricecurves" begin
    function tsim()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        return sim
    end

    function posyopts()
        return Dict(
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
    end

    function makesnapshot()
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec1, elec2, co2
    end

    # genpricecurves: one column per electricity node; rows are hourly prices sorted descending.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.genpricecurves(s)
        @test "ZONE1" in names(df)
        @test "ZONE2" in names(df)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test issorted(df.ZONE1, rev=true)
        @test issorted(df.ZONE2, rev=true)
        zone1 = Nosy.getnodes(s, with=[:electricity])["ZONE1"]
        @test df.ZONE1 == sort(Nosy.dualprice(zone1), rev=true)
    end

    # Foreign price IC: ZONE2 column is exogenous import price sorted descending (no optimized ZONE2 node price).
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.genpricecurves(s)
        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")

        @test "ZONE1" in names(df)
        @test "ZONE2" in names(df)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test issorted(df.ZONE2, rev=true)
        @test df.ZONE2 == sort(Posy2.getexogenousprice(c), rev=true)
    end

    # Fully disabled price IC: the zone column is an hourly series of zeros, not a scalar.
    let
        snap, elec1, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 0.0, 0.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.genpricecurves(s)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test df.ZONE2 == zeros(Nosy.nhours(sim(s)))
    end
end
