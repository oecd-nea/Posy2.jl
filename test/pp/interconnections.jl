using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing interconnections" begin
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

    # Node IC: directed endpoints come from port topology, not name parsing; rewrite labels are "from > to".
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_ZONE1_ZONE2")
        @test Nosy.hastag(c, :function, "nodeinterconnection")
        @test Posy2._fromto_ic_internal(s, c) == ("ZONE1", "ZONE2")
        zone1_ics = Nosy.getcomponents(s, "ZONE1"; with=[:function => "interconnection", :function => "nodeinterconnection"])
        @test haskey(zone1_ics, Nosy.name(c))
        @test Posy2.rewrite_import_from_implicit(s, Nosy.name(c), c) == "ZONE1 > ZONE2"
        @test Posy2.rewrite_export_from_implicit(s, Nosy.name(c), c) == "ZONE2 > ZONE1"

        df = Posy2.gentimeseries(s)
        @test "ZONE1 > ZONE2" in names(df)
        @test "ZONE2 > ZONE1" in names(df)
    end

    # With 50 MW CCGT on both zones, ZONE1 internal import is 50 MW each hour (annual = 50 * nhours); no foreign corridors.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0, transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        expected_import = 50.0 * Nosy.nhours(sim(s))
        @test isapprox(Posy2.imports_internal(s, "ZONE1"; collapse=true), expected_import; rtol=1e-12)
        @test isapprox(Posy2.imports_all(s, "ZONE1"; collapse=true), expected_import; rtol=1e-12)
        @test isempty(Posy2.imports_foreign(s))
        @test Posy2.imports_foreign(s, "ZONE1"; collapse=true) == 0.0
        @test Posy2.exports_foreign(s, "ZONE1"; collapse=true) == 0.0
    end

    # Snapshot totals: imports_all equals internal plus foreign; exports_all equals exports_internal when no foreign IC exists.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        internal_total = sum(values(Posy2.imports_internal(s; collapse=true)))
        foreign_total = sum(values(Posy2.imports_foreign(s; collapse=true)), init=0.0)
        all_total = sum(values(Posy2.imports_all(s; collapse=true)))
        @test isapprox(all_total, internal_total + foreign_total; rtol=1e-12)
        @test isapprox(
            Posy2.exports_all(s, "ZONE1"; collapse=true),
            Posy2.exports_internal(s, "ZONE1"; collapse=true);
            rtol=1e-12,
        )
    end

    # imports_internal: collapse=true returns corridor totals; collapse=false returns hourly series keyed by neighbor zone.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        d = Posy2.imports_internal(s)
        dts_zone = Posy2.imports_internal(s, "ZONE1"; collapse=false)
        collapsed_zone = Posy2.imports_internal(s, "ZONE1"; collapse=true)
        dts_all = Posy2.imports_all(s, "ZONE1"; collapse=false)
        collapsed_all = Posy2.imports_all(s, "ZONE1"; collapse=true)

        @test d isa AbstractDict
        @test haskey(d, "ZONE2 > ZONE1")
        @test collapsed_zone == d["ZONE2 > ZONE1"]
        @test dts_zone isa AbstractDict
        @test haskey(dts_zone, "ZONE2")
        @test !(dts_zone["ZONE2"] isa Real)
        @test isapprox(d["ZONE2 > ZONE1"], sum(dts_zone["ZONE2"]); rtol=1e-12)

        @test dts_all isa AbstractDict
        @test haskey(dts_all, "ZONE2")
        @test !(dts_all["ZONE2"] isa Real)
        @test isapprox(collapsed_all, sum(dts_all["ZONE2"]); rtol=1e-12)
    end

    # exports_internal with collapse=false returns hourly series; annual values are the sum of hourly flows.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        d = Posy2.exports_internal(s)
        dts = Posy2.exports_internal(s; collapse=false)
        dts_all = Posy2.exports_all(s; collapse=false)

        @test d isa AbstractDict
        @test haskey(d, "ZONE2 > ZONE1")
        @test dts isa AbstractDict
        @test haskey(dts, "ZONE2 > ZONE1")
        @test !(dts["ZONE2 > ZONE1"] isa Real)
        @test isapprox(d["ZONE2 > ZONE1"], sum(dts["ZONE2 > ZONE1"]); rtol=1e-12)

        @test dts_all isa AbstractDict
        @test haskey(dts_all, "ZONE2 > ZONE1")
        @test !(dts_all["ZONE2 > ZONE1"] isa Real)
    end

    # _all_ic_directed_flows keys are (from, to) tuples; ZONE2->ZONE1 hourly sum matches imports_internal(ZONE1).
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        flows = Posy2._all_ic_directed_flows(s; collapse=false)
        @test haskey(flows, ("ZONE2", "ZONE1"))
        @test !(flows[("ZONE2", "ZONE1")] isa Real)
        @test isapprox(
            Posy2.imports_internal(s, "ZONE1"; collapse=true),
            sum(flows[("ZONE2", "ZONE1")]);
            rtol=1e-12,
        )
    end

    # Underscore zone names (ZONE_A, ZONE_B): topology helpers use connected ports, not string parsing of component names.
    let
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec_a = Node("ZONE_A", EnergyCarrier("electricity ZONE_A", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec_b = Node("ZONE_B", EnergyCarrier("electricity ZONE_B", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec_a, snap; coeff=1.0)
        makedispatchable("CCGT", elec_b, co2, snap; tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink(
            "IC_LINK", elec_a, elec_b, snap;
            cap=10_000.0, atob_availability=1.0, btoa_availability=1.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_LINK_ZONE_A_ZONE_B")
        @test Posy2._fromto_ic_internal(s, c) == ("ZONE_A", "ZONE_B")
        @test Posy2.rewrite_import_from_implicit(s, Nosy.name(c), c) == "ZONE_A > ZONE_B"
        @test Posy2.rewrite_export_from_implicit(s, Nosy.name(c), c) == "ZONE_B > ZONE_A"
        @test haskey(Posy2.imports_internal(s), "ZONE_B > ZONE_A")
    end

    # Internal price IC (neighbor ZONE2 is a model node): external topology is ZONE2->ZONE1; rewrite labels match import/export directions.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")
        @test Posy2._fromto_ic_external(s, c) == ("ZONE2", "ZONE1")
        @test Posy2.rewrite_import_from_implicit(s, Nosy.name(c), c) == "ZONE2 > ZONE1"
        @test Posy2.rewrite_export_from_implicit(s, Nosy.name(c), c) == "ZONE1 > ZONE2"
    end

    # Price IC whose neighbor matches an electricity node counts as internal import, not foreign.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        d = Posy2.imports_internal(s)
        collapsed_zone = Posy2.imports_internal(s, "ZONE1"; collapse=true)
        @test haskey(d, "ZONE2 > ZONE1")
        @test isempty(Posy2.imports_foreign(s))
        @test collapsed_zone == d["ZONE2 > ZONE1"]
    end

    # Foreign price IC (no generation on ZONE2): imports_foreign reports ZONE2->ZONE1; imports_internal is empty; all = internal + foreign.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")
        d = Posy2.imports_foreign(s)
        collapsed_zone = Posy2.imports_foreign(s, "ZONE1"; collapse=true)

        @test Posy2._fromto_ic_external(s, c) == ("ZONE2", "ZONE1")
        @test haskey(d, "ZONE2 > ZONE1")
        @test collapsed_zone == d["ZONE2 > ZONE1"]
        @test isempty(Posy2.imports_internal(s))

        internal_total = sum(values(Posy2.imports_internal(s; collapse=true)), init=0.0)
        foreign_total = sum(values(Posy2.imports_foreign(s; collapse=true)), init=0.0)
        all_total = sum(values(Posy2.imports_all(s; collapse=true)))
        @test isapprox(all_total, internal_total + foreign_total; rtol=1e-12)
        @test isapprox(foreign_total, d["ZONE2 > ZONE1"]; rtol=1e-12)
    end

    # Foreign imports with collapse=false return one hourly vector per corridor; collapsed annual equals sum of hours.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        collapsed = Posy2.imports_foreign(s; collapse=true)
        dts = Posy2.imports_foreign(s; collapse=false)
        dts_zone = Posy2.imports_foreign(s, "ZONE1"; collapse=false)
        collapsed_zone = Posy2.imports_foreign(s, "ZONE1"; collapse=true)

        @test haskey(dts, "ZONE2 > ZONE1")
        @test !(dts["ZONE2 > ZONE1"] isa Real)
        @test length(dts["ZONE2 > ZONE1"]) == Nosy.nhours(sim(s))
        @test isapprox(collapsed["ZONE2 > ZONE1"], sum(dts["ZONE2 > ZONE1"]); rtol=1e-12)

        @test haskey(dts_zone, "ZONE2")
        @test isapprox(collapsed_zone, sum(dts_zone["ZONE2"]); rtol=1e-12)
    end

    # Foreign exports with collapse=false return hourly series; collapsed annual equals sum of hours.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        collapsed = Posy2.exports_foreign(s; collapse=true)
        dts = Posy2.exports_foreign(s; collapse=false)
        dts_zone = Posy2.exports_foreign(s, "ZONE1"; collapse=false)
        collapsed_zone = Posy2.exports_foreign(s, "ZONE1"; collapse=true)

        @test haskey(dts, "ZONE1 > ZONE2")
        @test !(dts["ZONE1 > ZONE2"] isa Real)
        @test length(dts["ZONE1 > ZONE2"]) == Nosy.nhours(sim(s))
        @test isapprox(collapsed["ZONE1 > ZONE2"], sum(dts["ZONE1 > ZONE2"]); rtol=1e-12)
        @test haskey(dts_zone, "ZONE2")
        @test isapprox(collapsed_zone, sum(dts_zone["ZONE2"]); rtol=1e-12)
    end

    # Foreign price IC: exports_foreign at ZONE1 is zero when only import direction flows.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test Posy2.exports_foreign(s, "ZONE1"; collapse=true) == 0.0
        exp_dict = Posy2.exports_foreign(s; collapse=true)
        @test isempty(exp_dict) || all(iszero, values(exp_dict))
        @test isapprox(
            Posy2.exports_all(s, "ZONE1"; collapse=true),
            Posy2.exports_internal(s, "ZONE1"; collapse=true);
            rtol=1e-12,
        )
    end

    # Node IC between two self zones: self interconnection helpers throw; selfcosts imports/exports/rent are 0.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0, transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        cname = "IC_ZONE1_ZONE2"
        zone1 = Nosy.getnodes(s, with=[:electricity])["ZONE1"]
        vol_imp = Nosy.balance(zone1, :input, energy, collapse=false, aggregate=false)[cname]
        vol_exp = Nosy.balance(zone1, :output, energy, collapse=false, aggregate=false)[cname]
        expected_imp = sum(Nosy.dualprice(zone1) .* vol_imp)
        expected_exp = sum(Nosy.dualprice(zone1) .* vol_exp)
        @test_throws AssertionError Posy2.selfinterconnectioncost_node(s, cname)
        @test_throws AssertionError Posy2.selfinterconnectionrevenue_node(s, cname)
        @test_throws AssertionError Posy2.selfcongestionrent_node(s, cname)
        df = Posy2.selfcosts(s)
        row = first(df[df[!, :component] .== cname, :])
        @test row.imports == 0.0
        @test row.exports == 0.0
        @test row[Symbol("congestion rent")] == 0.0
        @test expected_imp > 0.0
        @test expected_exp == 0.0
    end

    # Foreign node IC (:foreign tag on ZONE2): selfcosts import/export/congestion rent row matches per component helpers.
    let
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        cname = "IC_ZONE1_ZONE2"
        df = Posy2.selfcosts(s)
        row = first(df[df[!, :component] .== cname, :])
        imp = Posy2.selfinterconnectioncost_node(s, cname)
        exp = Posy2.selfinterconnectionrevenue_node(s, cname)
        cr = Posy2.selfcongestionrent_node(s, cname)
        @test isapprox(row.imports, imp; rtol=1e-12)
        @test isapprox(row.exports, -exp; rtol=1e-12)
        @test isapprox(row[Symbol("congestion rent")], -cr; rtol=1e-12)
        @test imp > 0.0
    end

    # Price IC: geticprice returns hourly import and export price vectors of length nhours.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")
        prices = Posy2.geticprice(c)
        nh = Nosy.nhours(sim(s))
        @test haskey(prices, :import)
        @test haskey(prices, :export)
        @test length(prices[:import]) == nh
        @test length(prices[:export]) == nh
        @test prices[:import] isa Vector{Float64}
        @test prices[:export] isa Vector{Float64}
    end

    # Price IC: ispriceicmaxed returns hourly Bool vectors indicating import/export capacity saturation.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")
        dmaxed = Posy2.ispriceicmaxed(c)
        nh = Nosy.nhours(sim(s))
        @test haskey(dmaxed, :import)
        @test haskey(dmaxed, :export)
        @test length(dmaxed[:import]) == nh
        @test length(dmaxed[:export]) == nh
        @test eltype(dmaxed[:import]) == Bool
    end

    # Node IC: isnodeicmaxed returns hourly saturation flags on both input ports (forward and reverse).
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "IC_ZONE1_ZONE2")
        dmaxed = Posy2.isnodeicmaxed(c)
        nh = Nosy.nhours(sim(s))
        @test haskey(dmaxed, :input)
        @test haskey(dmaxed, :input2)
        @test length(dmaxed[:input]) == nh
        @test length(dmaxed[:input2]) == nh
        @test eltype(dmaxed[:input]) == Bool
    end

    # Non IC components: geticprice and isnodeicmaxed reject dispatchable sources.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", elec1, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, co2, snap; tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test_throws ArgumentError Posy2.geticprice(Nosy.getcomponent(s, "CCGT ZONE1"))
        @test_throws ArgumentError Posy2.isnodeicmaxed(Nosy.getcomponent(s, "CCGT ZONE1"))
        @test_throws ArgumentError Posy2.ispriceicmaxed(Nosy.getcomponent(s, "CCGT ZONE1"))
        @test_throws ArgumentError Posy2.getexogenousprice(Nosy.getcomponent(s, "IC_ZONE1_ZONE2"))
    end
end
