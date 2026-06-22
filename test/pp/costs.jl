using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing costs" begin
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

    # Aggregated self costs should satisfy Physical + Trade = Total.
    let
        s = makesnapshot()
        d = POSY2._dataline_costs_aggregated(s; showforeign=false)
        @test isapprox(d.d["Physical"] + d.d["Trade"], d.d["Total"]; rtol=1e-12)
        @test isapprox(POSY2.selfcost(s) / 1e9, d.d["Total"]; rtol=1e-12)
    end
end
