using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing pricecurves" begin
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
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, Inf, Inf, snap)

        Nosy.optimize!(snap, cost(snap))
        return extract(snap)
    end

    # genpricecurves should return hourly price duration curves sorted in descending order.
    let
        s = makesnapshot()
        df = POSY2.genpricecurves(s)
        @test "ZONE1" in names(df)
        @test "ZONE2" in names(df)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test issorted(df.ZONE1, rev=true)
        @test issorted(df.ZONE2, rev=true)
    end
end
