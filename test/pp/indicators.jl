using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing indicators" begin
    function tsim()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        return sim
    end

    function posyopts()
        return Dict(
            :posy => POSY2Options(
                data_dir=joinpath(dirname(@__DIR__), "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
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
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec1, elec2, h2, co2
    end

    function makesnapshot2()
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec, co2
    end

    # demand aggregates by connected electricity node, not by parsing "ZONE" from component names.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        d = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test haskey(d, "Other consumption ZONE1")
        @test haskey(d, "EL ZONE1")
        @test !haskey(d, "Other consumption ZONE2")
        @test isempty(POSY2.demand(s, "ZONE2"; aggregate=false, collapse=true))
    end

    # demand collapse=false returns hourly series; collapse=true annual equals sum (100 MW demand * nhours).
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        hourly = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=false)
        collapsed = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        expected = 100.0 * Nosy.nhours(sim(s))
        @test length(hourly["Other consumption ZONE1"]) == Nosy.nhours(sim(s))
        @test isapprox(collapsed["Other consumption ZONE1"], sum(hourly["Other consumption ZONE1"]); rtol=1e-12)
        @test isapprox(collapsed["Other consumption ZONE1"], expected; rtol=1e-12)
    end

    # demand aggregate=true sums all zone components; ZONE2 has no demand components so total is zero.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        total = POSY2.demand(s, "ZONE1"; aggregate=true, collapse=true)
        by_component = POSY2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test isapprox(total, sum(values(by_component)); rtol=1e-12)
        @test POSY2.demand(s, "ZONE2"; aggregate=true, collapse=true) == 0.0
    end

    # production: ZONE2 CCGT supplies ZONE1 (demand 100 MW/h); annual export matches hourly sum.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        by_component = POSY2.production(s; aggregate=false, collapse=true)
        hourly = POSY2.production(s; aggregate=false, collapse=false)
        collapsed = POSY2.production(s; aggregate=false, collapse=true)
        expected = 100.0 * Nosy.nhours(sim(s))

        @test haskey(by_component, "CCGT ZONE2")
        @test !haskey(by_component, "CCGT ZONE1")
        @test isapprox(collapsed["CCGT ZONE2"], sum(hourly["CCGT ZONE2"]); rtol=1e-12)
        @test isapprox(collapsed["CCGT ZONE2"], expected; rtol=1e-12)
    end

    # Node IC sense1 is forward (ZONE1 import); sense2 is reverse export — only forward flow in default fixture.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        sense1 = POSY2.ic_vol_sense1(s; aggregate=false, collapse=true)
        sense2 = POSY2.ic_vol_sense2(s; aggregate=false, collapse=true)
        hourly = POSY2.ic_vol_sense1(s; aggregate=false, collapse=false)

        @test haskey(sense1, "IC_ZONE1_ZONE2")
        @test isapprox(sense1["IC_ZONE1_ZONE2"], POSY2.imports_internal(s, "ZONE1"; collapse=true); rtol=1e-12)
        @test sense2["IC_ZONE1_ZONE2"] == 0.0
        @test sense1["IC_ZONE1_ZONE2"] != sense2["IC_ZONE1_ZONE2"]
        @test isapprox(sense1["IC_ZONE1_ZONE2"], sum(hourly["IC_ZONE1_ZONE2"]); rtol=1e-12)
        @test isapprox(POSY2.ic_vol_sense1(s; aggregate=true, collapse=true), POSY2.imports_internal(s, "ZONE1"; collapse=true); rtol=1e-12)
        @test POSY2.ic_vol_sense2(s; aggregate=true, collapse=true) == 0.0
    end

    # Price IC sense2 is import from foreign neighbor; sense1 is zero when only import direction flows.
    let
        snap, elec1, _, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        sense1 = POSY2.ic_vol_sense1(s; aggregate=false, collapse=true)
        sense2 = POSY2.ic_vol_sense2(s; aggregate=false, collapse=true)
        hourly = POSY2.ic_vol_sense2(s; aggregate=false, collapse=false)

        @test isapprox(sense2["IC_ZONE2_ZONE1"], POSY2.imports_foreign(s, "ZONE1"; collapse=true); rtol=1e-12)
        @test sense1["IC_ZONE2_ZONE1"] == 0.0
        @test sense1["IC_ZONE2_ZONE1"] != sense2["IC_ZONE2_ZONE1"]
        @test isapprox(sense2["IC_ZONE2_ZONE1"], sum(hourly["IC_ZONE2_ZONE1"]); rtol=1e-12)
    end

    # Battery storage helpers expose hourly charging/discharging/level series with correct collapse semantics.
    let
        snap, elec1, elec2, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makebatteries(
            "Battery", "Battery", elec1, snap;
            capin=100.0,
            eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        nh = Nosy.nhours(sim(s))
        char = POSY2.charging(s; aggregate=false, collapse=false)
        dis = POSY2.discharging(s; aggregate=false, collapse=false)
        lev = POSY2.storagelevel(s; aggregate=false)
        @test haskey(char, "charging Battery ZONE1")
        @test haskey(dis, "discharging Battery ZONE1")
        @test haskey(lev, "levelBattery ZONE1")
        @test length(char["charging Battery ZONE1"]) == nh
        collapsed = POSY2.charging(s; aggregate=false, collapse=true)
        hourly = POSY2.charging(s; aggregate=false, collapse=false)
        @test isapprox(collapsed["charging Battery ZONE1"], sum(hourly["charging Battery ZONE1"]); rtol=1e-12)
        dis_hourly = POSY2.discharging(s; aggregate=false, collapse=false)
        dis_collapsed = POSY2.discharging(s; aggregate=false, collapse=true)
        @test isapprox(dis_collapsed["discharging Battery ZONE1"], sum(dis_hourly["discharging Battery ZONE1"]); rtol=1e-12)
    end

    # No hydro inflow components: intake returns an empty dict.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test isempty(POSY2.intake(s; aggregate=false, collapse=false))
    end

    # Hydro reservoir: intake hourly series matches reservoir_inflow time series from fixture; collapse=true sums hours.
    let
        snap, elec, co2 = makesnapshot2()
        makedemand("Other consumption", "ZONE1", elec, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makehydroreservoir(
            "Hydro reservoir", "Battery", "ZONE1", elec, 5000.0, 100.0, 50_000_000.0, nothing, snap;
            gridlosses=0.0, eff=0.9,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=1.0,
            decommissioning=0.1, lifetime=30.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)
        inta = POSY2.intake(s; aggregate=false, collapse=false)
        key = "intake Hydro reservoir ZONE1"
        @test haskey(inta, key)
        @test length(inta[key]) == Nosy.nhours(sim(s))
        profile = gettimeseries(s, "ZONE1", "reservoir_inflow_2019")
        @test isapprox(inta[key], profile; rtol=1e-12)
        @test isapprox(
            POSY2.intake(s; aggregate=false, collapse=true)[key],
            sum(inta[key]);
            rtol=1e-12,
        )
    end

    # losses are reported per electricity node; zone curtailment is a non negative snapshot total.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makeelectrolyser(
            "EL", "PEM", elec1, h2, snap;
            cap=10.0, gridlosses=0.0, eff=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        los = POSY2.losses(s; aggregate=false, collapse=true)
        @test haskey(los, "ZONE1")
        @test haskey(los, "ZONE2")
        @test isapprox(
            los["ZONE1"],
            POSY2.losses(s, "EL ZONE1"; collapse=true) + POSY2.losses(s, "IC_ZONE1_ZONE2"; collapse=true);
            rtol=1e-12,
        )
        @test isapprox(los["ZONE2"], POSY2.losses(s, "CCGT ZONE2"; collapse=true); rtol=1e-12)
        curt = POSY2.curtailment(s; collapse=true)
        @test curt == 0.0
    end

    # Foreign price IC: ATC columns exist for both directions; gentimeseries stores ATC in GW (/1000).
    let
        snap, elec1, _, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        atc = POSY2.availabletransfercapacities(s)
        @test haskey(atc, "ATC ZONE2 > ZONE1")
        @test haskey(atc, "ATC ZONE1 > ZONE2")
        @test length(atc["ATC ZONE2 > ZONE1"]) == Nosy.nhours(sim(s))
        df = POSY2.gentimeseries(s)
        @test isapprox(df[!, "ATC ZONE2 > ZONE1"], atc["ATC ZONE2 > ZONE1"] / 1000.0; rtol=1e-12)
    end
end
