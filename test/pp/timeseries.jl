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
                discount_rate=0.05,
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
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test "Total demand" in names(df)
        @test "Total production" in names(df)
        @test "Total net interconnection" in names(df)
        # both endpoints are self nodes: the corridor is an internal transfer, not a boundary flow
        @test all(iszero, df[!, "Total net interconnection"])
    end

    # Hourly demand columns are in GW (100 MW -> 0.1 GW); annual sum matches MWh/1000.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
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
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        component_sum = sum(df[!, "Other consumption ZONE1"])
        @test isapprox(sum(df[!, "Total demand"]), component_sum; rtol=1e-12)
    end

    # Internal price IC: directed corridor columns (nhours rows); ZONE2->ZONE1 sum matches imports_internal in GW.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepricelink("ZONE2", elec1, snap; import_capacity=110.0, export_capacity=100.0, transaction_cost=1.)
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
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepricelink("ZONE2", elec1, snap; import_capacity=110.0, export_capacity=100.0, transaction_cost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        c = Nosy.getcomponent(s, "ZONE2_ZONE1")

        @test "price ZONE1" in names(df)
        @test "price ZONE2" in names(df)
        @test "price ZONE2_ZONE1" in names(df)
        @test isapprox(df[!, "price ZONE2_ZONE1"], Posy2.getexogenousprice(c); rtol=1e-12)
    end

    # storage/losses/charging/discharging/level totals present; Total demand sums consumption components.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        h2 = Node("H2", EnergyCarrier("hydrogen", sim(snap)), rule=:curtailed, tags=[:hydrogen])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makebatterystorage(
            "Battery", elec1, snap; tech_column="Battery",
            power_cap=100.0,
            roundtrip_eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        makedemandresponse("DR", elec1, 100.0, 50.0, snap)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
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
        zone_losses = sum(Posy2.losses(s; categories=Posy2.NETWORKLOSSES).losses)
        # GW column × 1000 vs MWh zone losses: rtol=1e-6 (looser than identity compares).
        @test isapprox(sum(df[!, "Total losses"]) * 1000.0, zone_losses; rtol=1e-6)
    end

    # A spilling reservoir reports aggregate and per-component spillage in GW.
    let
        snap, elec1, _, _ = makesnapshot()
        nh = Nosy.nhours(sim(snap))
        turbine = 10.0
        total_intake = 100.0 * turbine * nh # far above what the turbine can release
        makedemand("Other consumption", "ZONE1", elec1, snap; profile=turbine)
        makehydroreservoir(
            "Reservoir", "ZONE1", elec1, snap; tech_column="Battery",
            discharge_cap=turbine, charge_cap=0.0, intake=total_intake,
            spillage=true, intake_profile=1.0, grid_losses=0.0, roundtrip_eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0, decommissioning=0.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        @test "Total spillage" in names(df)
        @test "spillage Reservoir ZONE1" in names(df)
        @test isapprox(sum(df[!, "Total spillage"]), sum(df[!, "spillage Reservoir ZONE1"]); rtol=1e-12)
        # Periodic conservation: intake = generation + spillage.
        @test isapprox(
            sum(df[!, "Total intake"]),
            sum(df[!, "Total production"]) + sum(df[!, "Total spillage"]);
            rtol=1e-9,
        )
    end

    # Node IC columns use rewrite labels; export column sum matches imports_internal in GW.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        h2 = Node("H2", EnergyCarrier("hydrogen", sim(snap)), rule=:curtailed, tags=[:hydrogen])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makebatterystorage(
            "Battery", elec1, snap; tech_column="Battery",
            power_cap=100.0,
            roundtrip_eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        makedemandresponse("DR", elec1, 100.0, 50.0, snap)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
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
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("AC", elec1, elec2, snap; cap=2_000.0, dc=false)
        maketransmissionlink("DC", elec1, elec2, snap; cap=500.0, dc=true)
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

    # Node IC with a :foreign-tagged endpoint: gentimeseries exports ATC columns in GW.
    let
        _sim = tsim()
        snap = Snapshot(_sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", _sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink(
            "IC", elec1, elec2, snap;
            cap=10_000.0, atob_availability=0.8, btoa_availability=0.5,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        df = Posy2.gentimeseries(s)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test "ATC ZONE1 > ZONE2" in names(df)
        @test "ATC ZONE2 > ZONE1" in names(df)
        @test all(isapprox.(df[!, "ATC ZONE1 > ZONE2"], 8.0; rtol=1e-12))
        @test all(isapprox.(df[!, "ATC ZONE2 > ZONE1"], 5.0; rtol=1e-12))
        @test "ZONE1 > ZONE2" in names(df)
        @test "ZONE2 > ZONE1" in names(df)
        # ZONE2 is the foreign endpoint: net interconnection is imports from it minus exports to it
        @test isapprox(df[!, "Total net interconnection"], df[!, "ZONE2 > ZONE1"] .- df[!, "ZONE1 > ZONE2"]; rtol=1e-12)
    end

    # Fully disabled price IC (both directions numerically zero, no spot price supplied):
    # the exogenous price is still an hourly series, so gentimeseries builds.
    let
        snap, elec1, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepricelink("ZONE2", elec1, snap; import_capacity=0.0, export_capacity=0.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "ZONE2_ZONE1")
        price = Posy2.getexogenousprice(c)
        @test price == zeros(Nosy.nhours(sim(s)))

        df = Posy2.gentimeseries(s)
        @test size(df, 1) == Nosy.nhours(sim(s))
        @test df[!, "price ZONE2_ZONE1"] == price
        @test all(iszero, df[!, "ZONE2 > ZONE1"])
        @test all(iszero, df[!, "ZONE1 > ZONE2"])
    end
end
