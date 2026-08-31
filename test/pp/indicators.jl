using Posy2
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
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        d = Posy2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test haskey(d, "Other consumption ZONE1")
        @test haskey(d, "EL ZONE1")
        @test !haskey(d, "Other consumption ZONE2")
        @test isempty(Posy2.demand(s, "ZONE2"; aggregate=false, collapse=true))
    end

    # demand collapse=false returns hourly series; collapse=true annual equals sum (100 MW demand * nhours).
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        hourly = Posy2.demand(s, "ZONE1"; aggregate=false, collapse=false)
        collapsed = Posy2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        expected = 100.0 * Nosy.nhours(sim(s))
        @test length(hourly["Other consumption ZONE1"]) == Nosy.nhours(sim(s))
        @test isapprox(collapsed["Other consumption ZONE1"], sum(hourly["Other consumption ZONE1"]); rtol=1e-12)
        @test isapprox(collapsed["Other consumption ZONE1"], expected; rtol=1e-12)
    end

    # demand aggregate=true sums all zone components; ZONE2 has no demand components so total is zero.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        total = Posy2.demand(s, "ZONE1"; aggregate=true, collapse=true)
        by_component = Posy2.demand(s, "ZONE1"; aggregate=false, collapse=true)
        @test isapprox(total, sum(values(by_component)); rtol=1e-12)
        @test Posy2.demand(s, "ZONE2"; aggregate=true, collapse=true) == 0.0
    end

    # production: ZONE2 CCGT supplies ZONE1 (demand 100 MW/h); annual export matches hourly sum.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        by_component = Posy2.production(s; aggregate=false, collapse=true)
        hourly = Posy2.production(s; aggregate=false, collapse=false)
        collapsed = Posy2.production(s; aggregate=false, collapse=true)
        expected = 100.0 * Nosy.nhours(sim(s))

        @test haskey(by_component, "CCGT ZONE2")
        @test !haskey(by_component, "CCGT ZONE1")
        @test isapprox(collapsed["CCGT ZONE2"], sum(hourly["CCGT ZONE2"]); rtol=1e-12)
        @test isapprox(collapsed["CCGT ZONE2"], expected; rtol=1e-12)
    end

    # An internal corridor between two self nodes carries flow but crosses no boundary: net is zero.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0, transaction_cost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test Posy2.imports_internal(s, "ZONE1"; collapse=true) > 0.0 # the corridor does flow
        @test Posy2.netinterconnection(s; collapse=true) == 0.0
        @test all(iszero, Posy2.netinterconnection(s; collapse=false))
        # neither endpoint is tagged :foreign, so this internal link reports no ATC
        @test isempty(Posy2.availabletransfercapacities(s))
    end

    # Net interconnection is boundary net imports and does not depend on the builder's endpoint order.
    let
        function foreignfixture(reversed::Bool)
            sim = tsim()
            snap = Snapshot(sim, posyopts())
            elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
            elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
            co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
            makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
            makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
            if reversed
                maketransmissionlink("IC", elec2, elec1, snap; cap=10_000.0, transaction_cost=1.)
            else
                maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0, transaction_cost=1.)
            end
            Nosy.optimize!(snap, cost(snap))
            return extract(snap)
        end

        s = foreignfixture(false)
        srev = foreignfixture(true)
        net = Posy2.netinterconnection(s; collapse=true)

        # ZONE2 supplies ZONE1 across the boundary: positive net imports, matching the annual layer
        @test net > 0.0
        @test isapprox(net, Posy2.imports_foreign(s, "ZONE1"; collapse=true); rtol=1e-12)
        @test isapprox(net, Posy2.netinterconnection(srev; collapse=true); rtol=1e-12)
        @test isapprox(net, sum(Posy2.netinterconnection(s; collapse=false)); rtol=1e-12)
    end

    # Price ICs cross the boundary by construction: import-only corridor gives positive net imports.
    let
        snap, elec1, _, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makepricelink("ZONE2", elec1, snap; import_cap=110.0, export_cap=100.0, transaction_cost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        net = Posy2.netinterconnection(s; collapse=true)
        @test net > 0.0
        @test isapprox(net, Posy2.imports_foreign(s, "ZONE1"; collapse=true); rtol=1e-12)
        @test isapprox(net, sum(Posy2.netinterconnection(s; collapse=false)); rtol=1e-12)
    end

    # A price IC built with foreign=false prices another internal zone: it crosses no boundary.
    let
        snap, elec1, _, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makepricelink("ZONE2", elec1, snap; import_cap=110.0, export_cap=100.0, neighbor_is_foreign=false, transaction_cost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        c = Nosy.getcomponent(s, "ZONE2_ZONE1")
        @test !hastag(c, :function, "foreign")
        @test sum(balance(c, :output, energy, collapse=false, aggregate=false)["output"]) > 0.0 # the corridor does flow
        @test Posy2.netinterconnection(s; collapse=true) == 0.0
        @test all(iszero, Posy2.netinterconnection(s; collapse=false))
    end

    # Battery storage helpers expose hourly charging/discharging/level series with correct collapse semantics.
    let
        snap, elec1, elec2, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makebatterystorage(
            "Battery", elec1, snap; tech_column="Battery",
            power_cap=100.0,
            roundtrip_eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        nh = Nosy.nhours(sim(s))
        char = Posy2.charging(s; aggregate=false, collapse=false)
        dis = Posy2.discharging(s; aggregate=false, collapse=false)
        lev = Posy2.storagelevel(s; aggregate=false)
        @test haskey(char, "charging Battery ZONE1")
        @test haskey(dis, "discharging Battery ZONE1")
        @test haskey(lev, "level Battery ZONE1")
        @test length(char["charging Battery ZONE1"]) == nh
        collapsed = Posy2.charging(s; aggregate=false, collapse=true)
        hourly = Posy2.charging(s; aggregate=false, collapse=false)
        @test isapprox(collapsed["charging Battery ZONE1"], sum(hourly["charging Battery ZONE1"]); rtol=1e-12)
        dis_hourly = Posy2.discharging(s; aggregate=false, collapse=false)
        dis_collapsed = Posy2.discharging(s; aggregate=false, collapse=true)
        @test isapprox(dis_collapsed["discharging Battery ZONE1"], sum(dis_hourly["discharging Battery ZONE1"]); rtol=1e-12)
    end

    # No hydro-intake components: intake returns an empty dict.
    let
        snap, elec1, elec2, h2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeelectrolyser(
            "EL", elec1, h2, snap; tech_column="PEM",
            cap=10.0, grid_losses=0.0, efficiency=0.8,
            overnight_cost=1200.0, om_fixed_cost=5.0, decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0, om_var_cost=1.0,
        )
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test isempty(Posy2.intake(s; aggregate=false, collapse=false))
        @test isempty(Posy2.spillage(s; aggregate=false, collapse=false))
        # An empty result aggregates to the neutral element of the requested
        # shape, not to an hourly vector of zeros in both cases.
        @test Posy2.intake(s; aggregate=true, collapse=true) == 0.0
        @test Posy2.spillage(s; aggregate=true, collapse=true) == 0.0
        @test Posy2.intake(s; aggregate=true, collapse=false) == zeros(Nosy.nhours(sim(s)))
        @test Posy2.spillage(s; aggregate=true, collapse=false) == zeros(Nosy.nhours(sim(s)))
    end

    # Hydro reservoir: normalized intake matches the workbook shape and requested total.
    let
        snap, elec, co2 = makesnapshot2()
        makedemand("Other consumption", "ZONE1", elec, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        profile = gettimeseries(snap, "ZONE1", "reservoir_inflow_2019")
        makehydroreservoir(
            "Hydro reservoir", "ZONE1", elec, snap; tech_column="Battery",
            discharge_cap=5000.0, charge_cap=100.0, intake=sum(profile),
            energy_cap=50_000_000.0, weather_year=2019,
            grid_losses=0.0, roundtrip_eff=0.9,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=1.0,
            decommissioning=0.1, lifetime=30.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)
        inta = Posy2.intake(s; aggregate=false, collapse=false)
        key = "intake Hydro reservoir ZONE1"
        @test haskey(inta, key)
        @test length(inta[key]) == Nosy.nhours(sim(s))
        @test isapprox(inta[key], profile; rtol=1e-12)
        @test isapprox(
            Posy2.intake(s; aggregate=false, collapse=true)[key],
            sum(inta[key]);
            rtol=1e-12,
        )
        # Collapsed aggregation returns a scalar, not a series.
        agg = Posy2.intake(s; aggregate=true, collapse=true)
        @test agg isa Real
        @test isapprox(agg, sum(inta[key]); rtol=1e-12)
        @test isapprox(Posy2.intake(s; aggregate=true, collapse=false), inta[key]; rtol=1e-12)
    end

    # Spilling reservoir: spillage aggregates in both hourly and collapsed shapes.
    let
        snap, elec, co2 = makesnapshot2()
        turbine = 10.0
        total_intake = 100.0 * turbine * Nosy.nhours(sim(snap))
        makedemand("Other consumption", "ZONE1", elec, snap; profile=turbine)
        makedispatchable("CCGT", elec, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makehydroreservoir(
            "Hydro reservoir", "ZONE1", elec, snap; tech_column="Battery",
            discharge_cap=turbine, charge_cap=0.0, intake=total_intake,
            spillage=true, intake_profile=1.0, grid_losses=0.0, roundtrip_eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0, decommissioning=0.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        spil = Posy2.spillage(s; aggregate=false, collapse=false)
        key = "spillage Hydro reservoir ZONE1"
        @test haskey(spil, key)
        @test length(spil[key]) == Nosy.nhours(sim(s))
        agg = Posy2.spillage(s; aggregate=true, collapse=true)
        @test agg isa Real
        @test isapprox(agg, sum(spil[key]); rtol=1e-9)
        @test isapprox(Posy2.spillage(s; aggregate=true, collapse=false), spil[key]; rtol=1e-9)
        @test isapprox(
            Posy2.spillage(s; aggregate=false, collapse=true)[key],
            sum(spil[key]);
            rtol=1e-9,
        )
    end

    # Foreign price IC: ATC columns exist for both directions; gentimeseries stores ATC in GW (/1000).
    let
        snap, elec1, _, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makepricelink("ZONE2", elec1, snap; import_cap=110.0, export_cap=100.0, transaction_cost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        atc = Posy2.availabletransfercapacities(s)
        @test haskey(atc, "ATC ZONE2 > ZONE1")
        @test haskey(atc, "ATC ZONE1 > ZONE2")
        @test length(atc["ATC ZONE2 > ZONE1"]) == Nosy.nhours(sim(s))
        df = Posy2.gentimeseries(s)
        @test isapprox(df[!, "ATC ZONE2 > ZONE1"], atc["ATC ZONE2 > ZONE1"] / 1000.0; rtol=1e-12)
    end

    # Node IC with a :foreign-tagged endpoint counts as foreign (no builder flag); ATC directions come
    # from port topology (input: from->to, input2: to->from), not the price IC neighbor tag.
    let
        _sim = tsim()
        snap = Snapshot(_sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", _sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink(
            "IC", elec1, elec2, snap;
            cap=10_000.0, a_to_b_availability=0.8, b_to_a_availability=0.5,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        atc = Posy2.availabletransfercapacities(s)
        @test haskey(atc, "ATC ZONE1 > ZONE2")
        @test haskey(atc, "ATC ZONE2 > ZONE1")
        @test length(atc["ATC ZONE1 > ZONE2"]) == Nosy.nhours(sim(s))
        @test all(isapprox.(atc["ATC ZONE1 > ZONE2"], 10_000.0 * 0.8; rtol=1e-12))
        @test all(isapprox.(atc["ATC ZONE2 > ZONE1"], 10_000.0 * 0.5; rtol=1e-12))
    end

    # A zero directional multiplier disables that direction while retaining the
    # shared installed-capacity series in both directions.
    let
        _sim = tsim()
        snap = Snapshot(_sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", _sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink(
            "IC", elec1, elec2, snap;
            cap=10_000.0, a_to_b_availability=1.0, b_to_a_availability=0.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        atc = Posy2.availabletransfercapacities(s)
        @test haskey(atc, "ATC ZONE1 > ZONE2")
        @test haskey(atc, "ATC ZONE2 > ZONE1")
        @test all(==(10_000.0), atc["ATC ZONE1 > ZONE2"])
        @test length(atc["ATC ZONE2 > ZONE1"]) == Nosy.nhours(sim(s))
        @test all(iszero, atc["ATC ZONE2 > ZONE1"])

        df = Posy2.gentimeseries(s)
        @test "ATC ZONE1 > ZONE2" in names(df)
        @test "ATC ZONE2 > ZONE1" in names(df)
    end

    # Foreign AC + DC on one corridor: ATC sums per directed pair, matching corridor volume columns.
    let
        _sim = tsim()
        snap = Snapshot(_sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", _sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink(
            "AC", elec1, elec2, snap;
            cap=2_000.0, a_to_b_availability=1.0, b_to_a_availability=0.5,
        )
        maketransmissionlink(
            "DC", elec1, elec2, snap;
            cap=500.0, dc=true, a_to_b_availability=1.0, b_to_a_availability=0.5,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        atc = Posy2.availabletransfercapacities(s)
        @test all(isapprox.(atc["ATC ZONE1 > ZONE2"], 2_500.0; rtol=1e-12))
        @test all(isapprox.(atc["ATC ZONE2 > ZONE1"], 1_250.0; rtol=1e-12))
    end
end
