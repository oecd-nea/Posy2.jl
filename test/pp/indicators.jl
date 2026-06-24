using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing indicators" begin
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
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, Inf, Inf, snap)

        Nosy.optimize!(snap, cost(snap))
        return extract(snap)
    end

    # demand(s, nodename) should return components connected to that node.
    let
        s = makesnapshot()
        d = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test haskey(d, "Other consumption ZONE1")
        @test haskey(d, "EL ZONE1")
        @test !haskey(d, "Other consumption ZONE2")
        @test isempty(POSY2.demand(s, "ZONE2"; aggregate=false, collapse=true))
    end

    # collapse=false returns hourly values and collapse=true matches their sum.
    let
        s = makesnapshot()
        hourly = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=false)
        collapsed = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test length(hourly["Other consumption ZONE1"]) == Nosy.nhours(sim(s))
        @test isapprox(collapsed["Other consumption ZONE1"], sum(hourly["Other consumption ZONE1"]); rtol=1e-12)
        @test collapsed["Other consumption ZONE1"] ≈ 876_000.0
    end

    # aggregate=true, collapse=true returns a zone total.
    let
        s = makesnapshot()
        total = POSY2.demand(s, "ZONE1"; aggregate=true, collapse=true)
        by_component = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test isapprox(total, sum(values(by_component)); rtol=1e-12)
        @test POSY2.demand(s, "ZONE2"; aggregate=true, collapse=true) == 0.0
    end
end
