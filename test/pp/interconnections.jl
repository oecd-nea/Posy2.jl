using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing interconnections" begin
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
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, Inf, Inf, snap)

        Nosy.optimize!(snap, cost(snap))
        return extract(snap)
    end

    # Node interconnection topology and direction labels.
    let
        s = makesnapshot()
        c = Nosy.getcomponent(s, "IC_ZONE1_ZONE2")
        @test POSY2._fromto_ic_internal(s, c) == ("ZONE1", "ZONE2")
        @test POSY2.rewrite_import_from_implicit(s, Nosy.name(c), c) == "ZONE1 > ZONE2"
        @test POSY2.rewrite_export_from_implicit(s, Nosy.name(c), c) == "ZONE2 > ZONE1"
        @test POSY2._nodeic_connected_nodes(s, c) == ["ZONE1", "ZONE2"]

        df = POSY2.gentimeseries(s)
        @test "ZONE1 > ZONE2" in names(df)
        @test "ZONE2 > ZONE1" in names(df)
    end

    # Internal import summary should match the detailed interconnection matrix.
    let
        s = makesnapshot()
        d = POSY2.imports_internal(s)
        @test d isa AbstractDict
        @test haskey(d, "ZONE2 > ZONE1")
        @test POSY2.imports_internal(s, "ZONE1"; collapse=true) == d["ZONE2 > ZONE1"]
        @test POSY2.imports_internal(s, "ZONE1"; collapse=false) isa AbstractDict
        @test haskey(POSY2.imports_internal(s, "ZONE1"; collapse=false), "ZONE2")
        @test POSY2.imports_all(s, "ZONE1"; collapse=false) isa AbstractDict
        @test haskey(POSY2.imports_all(s, "ZONE1"; collapse=false), "ZONE2")

        df = POSY2._interco_vol_detailed(s; collapse=true, addtotal=false)
        v = df[df[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        @test v == d["ZONE2 > ZONE1"]
    end

    # Internal export summary should be returned as a dictionary-like structure.
    let
        s = makesnapshot()
        d = POSY2.exports_internal(s)
        @test d isa AbstractDict
        @test haskey(d, "ZONE2 > ZONE1")

        dts = POSY2.exports_internal(s; collapse=false)
        @test dts isa AbstractDict
        @test haskey(dts, "ZONE2 > ZONE1")
        @test !(dts["ZONE2 > ZONE1"] isa Number)

        dts_all = POSY2.exports_all(s; collapse=false)
        @test dts_all isa AbstractDict
        @test haskey(dts_all, "ZONE2 > ZONE1")
        @test !(dts_all["ZONE2 > ZONE1"] isa Number)
    end
end
