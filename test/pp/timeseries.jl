using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing timeseries" begin
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

    # gentimeseries has one row per hour and includes aggregate demand/production/net IC columns.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test "Total demand" in names(df)
        @test "Total production" in names(df)
        @test "Total net interconnection" in names(df)
    end

    # Hourly demand columns are in GW (100 MW -> 0.1 GW); annual sum matches MWh/1000.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        expected_annual_gwh = 100.0 * Nosy.nhours(sim(s)) / 1000.0
        @test isapprox(df[1, "Other consumption ZONE1"], 0.1; rtol=1e-12)
        @test isapprox(sum(df[!, "Other consumption ZONE1"]), expected_annual_gwh; rtol=1e-12)
    end

    # Total demand column equals sum of component demand columns.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        component_sum = sum(df[!, "Other consumption ZONE1"])
        @test isapprox(sum(df[!, "Total demand"]), component_sum; rtol=1e-12)
    end

    # Internal price IC: directed corridor columns (nhours rows); ZONE2->ZONE1 sum matches imports_internal in GW.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        @test "ZONE2 > ZONE1" in names(df)
        @test "ZONE1 > ZONE2" in names(df)
        @test size(df, 1) == Nosy.nhours(sim(s))
        expected = Posy2.imports_internal(s, "ZONE1"; collapse=true) / 1000.0
        @test isapprox(sum(df[!, "ZONE2 > ZONE1"]), expected; rtol=1e-12)
    end

    # gentimeseries includes node prices and exogenous price IC prices.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        c = Nosy.getcomponent(s, "IC_ZONE2_ZONE1")

        @test "price ZONE1" in names(df)
        @test "price ZONE2" in names(df)
        @test "price IC_ZONE2_ZONE1" in names(df)
        @test isapprox(df[!, "price IC_ZONE2_ZONE1"], Posy2.getexogenousprice(c); rtol=1e-12)
    end

    # storage/losses/charging/discharging/level totals present; Total demand sums consumption components.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        h2 = Node("H2", EnergyCarrier("hydrogen", sim(snap)), rule=:curtailed, tags=[:hydrogen])
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makebatterystorage(
            "Battery", "Battery", elec1, snap;
            capin=100.0,
            eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        makedemandresponse("DR", elec1, 100.0, 50.0, snap)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        nh = Nosy.nhours(sim(s))
        @test "Battery ZONE1" in names(df) || "charging Battery ZONE1" in names(df)
        @test "Total losses" in names(df)
        @test "Total charging" in names(df)
        @test "Total discharging" in names(df)
        @test "Total level" in names(df)
        @test size(df, 1) == nh
        @test isapprox(sum(df[!, "Total demand"]), sum(df[!, "Other consumption ZONE1"]) + sum(df[!, "EL ZONE1"]); rtol=1e-12)
        zone_losses = sum(values(Posy2.losses(s; aggregate=false, collapse=true)))
        # GW column × 1000 vs MWh zone losses: rtol=1e-6 (looser than identity compares).
        @test isapprox(sum(df[!, "Total losses"]) * 1000.0, zone_losses; rtol=1e-6)
    end

    # Node IC columns use rewrite labels; export column sum matches imports_internal in GW.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        h2 = Node("H2", EnergyCarrier("hydrogen", sim(snap)), rule=:curtailed, tags=[:hydrogen])
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makebatterystorage(
            "Battery", "Battery", elec1, snap;
            capin=100.0,
            eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        makedemandresponse("DR", elec1, 100.0, 50.0, snap)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        c = Nosy.getcomponent(s, "IC_ZONE1_ZONE2")
        imp_col = Posy2.rewrite_import_from_implicit(s, Nosy.name(c), c)
        exp_col = Posy2.rewrite_export_from_implicit(s, Nosy.name(c), c)
        @test imp_col in names(df)
        @test exp_col in names(df)
        @test isapprox(
            sum(df[!, exp_col]),
            Posy2.imports_internal(s, "ZONE1"; collapse=true) / 1000.0;
            rtol=1e-12,
        )
    end

    # Same directed pair with AC + DC: timeseries corridor column sums both flows (GW).
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("AC", elec1, elec2, 2_000.0, 2_000.0, snap; dc=false)
        makenodeinterco("DC", elec1, elec2, 500.0, 500.0, snap; dc=true)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        ac = Nosy.getcomponent(s, "AC_ZONE1_ZONE2")
        dc = Nosy.getcomponent(s, "DC_ZONE1_ZONE2")
        col = Posy2.rewrite_import_from_implicit(s, Nosy.name(ac), ac)
        @test col == Posy2.rewrite_import_from_implicit(s, Nosy.name(dc), dc)
        @test count(==(col), names(df)) == 1

        ac_fwd = balance(ac, :output, energy, collapse=false, aggregate=false)["output"] / 1000.0
        dc_fwd = balance(dc, :output, energy, collapse=false, aggregate=false)["output"] / 1000.0
        @test isapprox(df[!, col], ac_fwd .+ dc_fwd; rtol=1e-12)
    end
end
