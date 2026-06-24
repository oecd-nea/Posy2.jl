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
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, Inf, Inf, snap)

        Nosy.optimize!(snap, cost(snap))
        return extract(snap)
    end

    # Node interconnection topology and flow direction labels.
    let
        s = makesnapshot()
        c = Nosy.getcomponent(s, "IC_ZONE1_ZONE2")
        @test POSY2._fromto_ic_internal(s, c) == ("ZONE1", "ZONE2")
        @test POSY2._nodeic_connected_nodes(s, c) == ["ZONE1", "ZONE2"]
        @test POSY2.rewrite_import_from_implicit(s, Nosy.name(c), c) == "ZONE1 > ZONE2"
        @test POSY2.rewrite_export_from_implicit(s, Nosy.name(c), c) == "ZONE2 > ZONE1"

        df = POSY2.gentimeseries(s)
        @test "ZONE1 > ZONE2" in names(df)
        @test "ZONE2 > ZONE1" in names(df)
    end

    # ZONE1 import volume with 100 MWhe/h demand and 50 MW caps on both zones.
    let
        s = makesnapshot()
        expected_import = 438_000.0
        @test POSY2.imports_internal(s, "ZONE1"; collapse=true) ≈ expected_import
        @test POSY2.imports_all(s, "ZONE1"; collapse=true) ≈ expected_import
        @test isempty(POSY2.imports_foreign(s))
    end

    # Foreign import/export with collapse=true should return 0.0 when no foreign IC exists.
    let
        s = makesnapshot()
        @test POSY2.imports_foreign(s, "ZONE1"; collapse=true) == 0.0
        @test POSY2.exports_foreign(s, "ZONE1"; collapse=true) == 0.0
    end

    # Global import summaries should satisfy all = internal + foreign when collapsed.
    let
        s = makesnapshot()
        internal_total = sum(values(POSY2.imports_internal(s; collapse=true)))
        foreign_total = sum(values(POSY2.imports_foreign(s; collapse=true)), init=0.0)
        all_total = sum(values(POSY2.imports_all(s; collapse=true)))
        @test isapprox(all_total, internal_total + foreign_total; rtol=1e-12)
        @test isapprox(
            POSY2.exports_all(s, "ZONE1"; collapse=true),
            POSY2.exports_internal(s, "ZONE1"; collapse=true);
            rtol=1e-12,
        )
    end

    # Internal import summary with global dict, nodename filter, and collapse flag.
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
    end

    # Internal export summary with collapse=false returning time series, not scalars.
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

    function makesnapshot_price_ic()
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
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 100.0, 100.0, snap)
        Nosy.optimize!(snap, cost(snap))
        return extract(snap)
    end

    # Price interconnection flow labels from external zone tag and local node.
    let
        s = makesnapshot_price_ic()
        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")
        @test POSY2.rewrite_import_from_implicit(s, Nosy.name(c), c) == "ZONE2 > ZONE1"
        @test POSY2.rewrite_export_from_implicit(s, Nosy.name(c), c) == "ZONE1 > ZONE2"
    end
end
