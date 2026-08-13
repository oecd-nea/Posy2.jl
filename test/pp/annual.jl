using Posy2
using Nosy
using Test
using JuMP
using HiGHS
using DataFrames

@testset "Post processing annual" begin
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

    function makesnapshot2()
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec1, elec2, elec3, co2
    end

    # Aggregated costs: Trade is interconnection columns and Physical is the rest. Total matches selfcost.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        d = Posy2._dataline_costs_aggregated(s; showforeign=false)
        df = Posy2.selfcosts(s)
        allrow = first(df[df[!, :component] .== "all", :])
        trade = (allrow.imports + allrow.exports + allrow[Symbol("congestion rent")]) / 1e9
        @test isapprox(d.d["Trade"], trade; rtol=1e-12)
        @test isapprox(d.d["Physical"], d.d["Total"] - trade; rtol=1e-12)
        @test isapprox(Posy2.selfcost(s) / 1e9, d.d["Total"]; rtol=1e-12)
    end

    # Internal-only model: foreign import/export datalines are zero at every electricity node (TWh/y scale).
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        for (k, _) in Nosy.getnodes(s, with=[:electricity], without=[:foreign])
            @test Posy2.imports_foreign(s, k; collapse=true) / 1e6 == 0.0
            @test Posy2.exports_foreign(s, k; collapse=true) / 1e6 == 0.0
        end
    end

    # IC volume matrix: ZONE2->ZONE1 cell is annual MWh flow divided by 1e6 (50 MW * nhours in default fixture).
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        expected_mwh = 50.0 * Nosy.nhours(sim(s))
        line = Posy2._dataline_ic_vol_detailed(s)
        @test line.unit == "TWh/y"
        v = line.d[line.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        @test isapprox(v, expected_mwh / 1e6; rtol=1e-12)
    end

    # IC capacity matrix: asymmetric forward/reverse caps (2000/3000 MW) are reported in GW (2.0/3.0).
    let
        snap, elec1, elec2, _ = makesnapshot()
        makenodeinterco("IC", elec1, elec2, 2_000.0, 3_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_ic_cap(s)
        @test line.unit == "GW"
        @test isapprox(line.d[line.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1], 2.0; rtol=1e-12)
        @test isapprox(line.d[line.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1], 3.0; rtol=1e-12)
    end

    # Same directed pair with AC + DC: total capacity/volume sum both; AC/DC tables split.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("AC", elec1, elec2, 2_000.0, 2_000.0, snap; dc=false)
        makenodeinterco("DC", elec1, elec2, 500.0, 500.0, snap; dc=true)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        cap = Posy2._dataline_ic_cap(s)
        @test cap.title == "Interconnection capacity"
        @test isapprox(cap.d[cap.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1], 2.5; rtol=1e-12)
        @test isapprox(cap.d[cap.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1], 2.5; rtol=1e-12)

        cap_ac = Posy2._dataline_ic_cap(s; kind=:AC)
        @test cap_ac.title == "Interconnection capacity (AC)"
        @test isapprox(cap_ac.d[cap_ac.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1], 2.0; rtol=1e-12)
        @test isapprox(cap_ac.d[cap_ac.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1], 2.0; rtol=1e-12)

        cap_dc = Posy2._dataline_ic_cap(s; kind=:DC)
        @test cap_dc.title == "Interconnection capacity (DC)"
        @test isapprox(cap_dc.d[cap_dc.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1], 0.5; rtol=1e-12)
        @test isapprox(cap_dc.d[cap_dc.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1], 0.5; rtol=1e-12)

        ac = Nosy.getcomponent(s, "AC_ZONE1_ZONE2")
        dc = Nosy.getcomponent(s, "DC_ZONE1_ZONE2")
        ac_fwd = balance(ac, :input, energy, collapse=true, aggregate=false)["input"]
        dc_fwd = balance(dc, :input, energy, collapse=true, aggregate=false)["input"]
        vol = Posy2._dataline_ic_vol_detailed(s)
        v = vol.d[vol.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        @test isapprox(v, (ac_fwd + dc_fwd) / 1e6; rtol=1e-12)

        vol_ac = Posy2._dataline_ic_vol_detailed(s; kind=:AC)
        @test vol_ac.title == "Interconnection volume (AC)"
        @test isapprox(vol_ac.d[vol_ac.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1], ac_fwd / 1e6; rtol=1e-12)

        vol_dc = Posy2._dataline_ic_vol_detailed(s; kind=:DC)
        @test vol_dc.title == "Interconnection volume (DC)"
        @test isapprox(vol_dc.d[vol_dc.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1], dc_fwd / 1e6; rtol=1e-12)
    end

    # IC exists but no injection: corridor cell is 0.0 (flow is zero), not missing.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)
        line = Posy2._dataline_ic_vol_detailed(s)
        v = line.d[line.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        @test v == 0.0
        @test !ismissing(v)
    end

    # Zone pair with no IC component: matrix cell stays missing, not zero.
    let
        snap, elec1, elec2, elec3, co2 = makesnapshot2()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec3, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC12", elec1, elec2, 10_000.0, 10_000.0, snap)
        makenodeinterco("IC23", elec2, elec3, Inf, Inf, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_ic_vol_detailed(s)
        v = line.d[line.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE3"][1]
        @test ismissing(v)
    end

    # IC volume matrix Total row equals column sum over non missing corridor rows.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_ic_vol_detailed(s)
        df = line.d
        datacols = [name for name in names(df)[2:end] if name != "> Total"]
        total_row = df[df[!, "From \\ To"] .== "Total >", :]
        for col in datacols
            expected = sum(df[i, col] for i in 1:(size(df, 1) - 1) if !ismissing(df[i, col]))
            @test isapprox(total_row[1, col], expected; rtol=1e-12)
        end
    end

    # NTC: steady 50 MW import stays below IC cap; hours at NTC are zero on both corridors.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_ic_hours_at_ntc(s)
        @test line.title == "Hours at NTC (AC or DC)"
        df = line.d
        v_import = df[df[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        v_export = df[df[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        @test isapprox(v_import, 0.0; rtol=1e-12)
        @test isapprox(v_export, 0.0; rtol=1e-12)
    end

    # Inf IC has no capacity behavior: NTC hours are missing, not zero.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makenodeinterco("IC", elec1, elec2, Inf, Inf, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)
        line = Posy2._dataline_ic_hours_at_ntc(s)
        df = line.d
        v12 = df[df[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        v21 = df[df[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        @test ismissing(v12)
        @test ismissing(v21)
    end

    # AC + DC on one corridor: AC/DC tables are separate; (AC or DC) is the hourly union.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("AC", elec1, elec2, 2_000.0, 2_000.0, snap; dc=false)
        makenodeinterco("DC", elec1, elec2, 500.0, 500.0, snap; dc=true)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        either = Posy2._dataline_ic_hours_at_ntc(s)
        line_ac = Posy2._dataline_ic_hours_at_ntc(s; kind=:AC)
        line_dc = Posy2._dataline_ic_hours_at_ntc(s; kind=:DC)
        @test either.title == "Hours at NTC (AC or DC)"
        @test line_ac.title == "Hours at NTC (AC)"
        @test line_dc.title == "Hours at NTC (DC)"

        either_h = either.d[either.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        ac_h = line_ac.d[line_ac.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        dc_h = line_dc.d[line_dc.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        @test either_h <= ac_h + dc_h
        @test either_h >= max(ac_h, dc_h)
    end

    # Internal price IC selfcosts row: imports/exports/congestion rent match dedicated priceIC helpers.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        cname = "IC_ZONE2_ZONE1"
        df = Posy2.selfcosts(s)
        row = first(df[df[!, :component] .== cname, :])
        imp = Posy2.selfinterconnectioncost_price(s, cname)
        exp = Posy2.selfinterconnectionrevenue_price(s, cname)
        cr = Posy2.selfcongestionrent_price(s, cname)
        @test isapprox(row.imports, imp; rtol=1e-12)
        @test isapprox(row.exports, -exp; rtol=1e-12)
        @test isapprox(row[Symbol("congestion rent")], -cr; rtol=1e-12)
    end

    # Demand/production dataline with foreign price IC: ZONE1 shows foreign imports only; internal imports are zero.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_demand_prod(s; showforeign=false)
        row = first(line.d[line.d.zone .== "ZONE1", :])
        expected = Posy2.imports_foreign(s, "ZONE1"; collapse=true) / 1e6
        @test isapprox(row["Imports (foreign)"], expected; rtol=1e-12)
        @test row["Imports (internal)"] == 0.0
    end

    # Internal price IC: volume matrix cell matches imports_internal converted to TWh/y.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        line = Posy2._dataline_ic_vol_detailed(s)
        v = line.d[line.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        expected = Posy2.imports_internal(s, "ZONE1"; collapse=true) / 1e6
        @test isapprox(v, expected; rtol=1e-12)
    end

    # Foreign IC volume datalines (imports, exports, net) match helper totals scaled to TWh/y.
    let
        snap, elec1, _, _ = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makepriceinterco("ZONE2", elec1, 110.0, 100.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        imp_line = Posy2._dataline_imports_vol(s)
        exp_line = Posy2._dataline_exports_vol(s)
        net_line = Posy2._dataline_net_ic_vol(s)
        imp = Posy2.imports_foreign(s; collapse=true)
        exp = Posy2.exports_foreign(s; collapse=true)
        @test isapprox(imp_line.d["ZONE2 > ZONE1"], imp["ZONE2 > ZONE1"] / 1e6; rtol=1e-12)
        @test isapprox(imp_line.d["Total"], sum(values(imp)) / 1e6; rtol=1e-12)
        @test isapprox(exp_line.d["ZONE1 > ZONE2"], exp["ZONE1 > ZONE2"] / 1e6; rtol=1e-12)
        @test isapprox(net_line.d["ZONE2 > ZONE1"], (imp["ZONE2 > ZONE1"] - exp["ZONE1 > ZONE2"]) / 1e6; rtol=1e-12)
    end

    # node helpers match component balances; ZONE1 energy balance closes with imports.
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
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        zone2_prod = Posy2.production(s, "ZONE2"; collapse=true)
        ccgt_z2_out = Nosy.balance(s, "CCGT ZONE2", :output, energy, collapse=true, aggregate=false)["output"]
        @test isapprox(zone2_prod, ccgt_z2_out; rtol=1e-12)
        el_out = Nosy.balance(s, "EL ZONE1", :input, energy, collapse=true, aggregate=false)["input"]
        @test isapprox(Posy2.electrolysis(s, "ZONE1"; collapse=true), el_out; rtol=1e-12)
        dr_out = Nosy.balance(s, "DR ZONE1", :output, energy, collapse=true, aggregate=true)
        @test isapprox(Posy2.demandresponse(s, "ZONE1"; collapse=true), dr_out; rtol=1e-12)
        char_bat = Posy2.charging(s; aggregate=false, collapse=true)["charging Battery ZONE1"]
        @test isapprox(Posy2.charging(s, "ZONE1"; collapse=true), char_bat; rtol=1e-12)
        @test Posy2.curtailment(s, "ZONE1"; collapse=true) == 0.0
        @test Posy2.losses(s, "IC_ZONE1_ZONE2"; collapse=true) == 0.0
        zone1_prod = Posy2.production(s, "ZONE1"; collapse=true)
        imports = Posy2.imports_internal(s, "ZONE1"; collapse=true)
        expected_demand = Posy2.demand(s, "ZONE1"; aggregate=true, collapse=true)
        dis_z1 = Posy2.discharging(s; aggregate=false, collapse=true)["discharging Battery ZONE1"]
        # Multi-term optimizer balance: rtol=1e-6 (looser than identity compares).
        @test isapprox(
            zone1_prod + imports,
            expected_demand + el_out + char_bat - dis_z1;
            rtol=1e-6,
        )
    end

    # Yearly demand/production datalines scale component balances from MWh to TWh/y.
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

        demand_line = Posy2._dataline_yearly_demand(s; showforeign=false)
        prod_line = Posy2._dataline_yearly_production(s; showforeign=false)
        row = first(demand_line.d[demand_line.d.zone .== "ZONE1", :])
        expected = Posy2.demand(s, "ZONE1"; aggregate=true, collapse=true) / 1e6
        @test isapprox(row["Other consumption"], expected; rtol=1e-12)
        prod_row = first(prod_line.d[prod_line.d.zone .== "ZONE2", :])
        @test isapprox(prod_row["CCGT"], Posy2.production(s, "ZONE2"; collapse=true) / 1e6; rtol=1e-12)
    end

    # Installed capacity datalines report GW/GWe from fixture caps (CCGT, EL, Battery, DR, H2 storage).
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

        prod_cap = Posy2._dataline_elec_prod_cap(s; showforeign=false)
        elec_cap = Posy2._dataline_electrolysis_cap(s; showforeign=false)
        stor_cap = Posy2._dataline_elec_storage_cap(s; showforeign=false)
        stor_dis = Posy2._dataline_elec_storage_discharge_cap(s; showforeign=false)
        stor_lvl = Posy2._dataline_elec_storage_cap_level(s; showforeign=false)
        dr_cap = Posy2._dataline_demandresponse_cap(s; showforeign=false)
        h2_cap = Posy2._dataline_hydrogen_storage_cap(s; showforeign=false)

        @test prod_cap.unit == "GWe"
        @test isapprox(first(prod_cap.d[prod_cap.d.zone .== "ZONE1", "CCGT"]), 0.05; rtol=1e-12)
        @test isapprox(first(prod_cap.d[prod_cap.d.zone .== "ZONE2", "CCGT"]), 0.3; rtol=1e-12)
        @test isapprox(first(elec_cap.d[elec_cap.d.zone .== "ZONE1", "EL"]), 0.01; rtol=1e-12)
        @test isapprox(first(stor_cap.d[stor_cap.d.zone .== "ZONE1", "Battery"]), 0.1; rtol=1e-12)
        @test isapprox(first(stor_dis.d[stor_dis.d.zone .== "ZONE1", "Battery"]), 0.1; rtol=1e-12)
        @test isapprox(first(stor_lvl.d[stor_lvl.d.zone .== "ZONE1", "Battery"]), 0.0004; rtol=1e-12)
        @test isapprox(first(dr_cap.d[dr_cap.d.zone .== "ZONE1", "DR"]), 0.1; rtol=1e-12)
        @test h2_cap.unit == "GWh"
    end

    # Yearly energy datalines use TWh/y for electricity flows and t/y for CO2; charging matches helper total.
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

        charge_line = Posy2._dataline_yearly_charging(s; showforeign=false)
        discharge_line = Posy2._dataline_yearly_discharging(s; showforeign=false)
        elec_line = Posy2._dataline_yearly_electrolysis(s; showforeign=false)
        dr_line = Posy2._dataline_yearly_demandresponse(s; showforeign=false)
        co2_line = Posy2._dataline_yearly_co2(s; showforeign=false)

        @test charge_line.unit == "TWh/y"
        @test discharge_line.unit == "TWh/y"
        @test elec_line.unit == "TWh/y"
        @test dr_line.unit == "TWh/y"
        @test co2_line.unit == "t/y"
        @test isapprox(
            first(charge_line.d[charge_line.d.zone .== "ZONE1", "Battery"]),
            Posy2.charging(s, "ZONE1"; collapse=true) / 1e6;
            rtol=1e-12,
        )
    end

    # Derived annual indicators: capacity factors (%) and LCOE (USD/MWhe) include weighted average row.
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

        cf_line = Posy2._dataline_capacityfactors(s; showforeign=false)
        el_cf_line = Posy2._dataline_electrolysers_capacityfactors(s; showforeign=false)
        lcoe_line = Posy2._dataline_lcoe(s; showforeign=false)
        @test cf_line.unit == "Energy %"
        @test el_cf_line.unit == "Energy %"
        @test lcoe_line.unit == "USD/MWhe"
        @test "CCGT" in names(cf_line.d)
        @test "EL" in names(el_cf_line.d)
        @test lcoe_line.d[end, "zone"] == "Weighted average"
    end

    # Cost/earnings/price received datalines use expected units (Bn USD, USD/MWh) and component detail table.
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

        cost_line = Posy2._dataline_yearly_cost(s; showforeign=false)
        earn_line = Posy2._dataline_yearly_earnings(s; showforeign=false)
        price_line = Posy2._dataline_yearly_price_received(s; showforeign=false)
        detail_line = Posy2._dataline_costs(s; showforeign=false)
        @test cost_line.unit == "Billions USD (2024)"
        @test earn_line.unit == "Billions USD (2024)"
        @test price_line.unit == "USD/MWh"
        @test detail_line.unit == "Billion USD (2024)"
        @test "Component" in names(detail_line.d)
        @test "total" in names(detail_line.d)
    end

    # showforeign=false (selfcosts) omits foreign node components; showforeign=true (costs) includes them.
    let
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        self_detail = Posy2._dataline_costs(s; showforeign=false)
        all_detail = Posy2._dataline_costs(s; showforeign=true)
        self_components = Set(self_detail.d.Component)
        all_components = Set(all_detail.d.Component)
        @test "CCGT ZONE2" in all_components
        @test !("CCGT ZONE2" in self_components)
        @test length(all_components) > length(self_components)
        ccgt_z2_total = first(all_detail.d[all_detail.d.Component .== "CCGT ZONE2", :total])
        @test ccgt_z2_total > 0.0
    end

    # without foreign nodes: self and all cost tables have the same component set.
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

        self_detail = Posy2._dataline_costs(s; showforeign=false)
        all_detail = Posy2._dataline_costs(s; showforeign=true)
        @test Set(self_detail.d.Component) == Set(all_detail.d.Component)
        @test isapprox(
            sum(skipmissing(self_detail.d.total)),
            sum(skipmissing(all_detail.d.total));
            rtol=1e-12,
        )
    end

    # Cost table cleanup: rows with all zero numeric columns are dropped.
    let
        df = DataFrame(component=["A", "B", "C"], fuel=[0.0, 1.0, 0.0], total=[0.0, 1.0, 0.0])
        Posy2._removezerorows!(df)
        @test df.component == ["B"]
    end

    # No evalprice: dualprice is nothing; earnings and price-received cells are missing.
    let
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec, co2, snap; cap=200.0, construction_profile=1.0, decommissioning_profile=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test isnothing(Nosy.dualprice(elec))
        earn_line = Posy2._dataline_yearly_earnings(s; showforeign=true)
        price_line = Posy2._dataline_yearly_price_received(s; showforeign=true)
        @test "CCGT" in names(earn_line.d)
        zone_earn = first(earn_line.d[earn_line.d.zone .== "ZONE1", :CCGT])
        zone_price = first(price_line.d[price_line.d.zone .== "ZONE1", :CCGT])
        @test ismissing(zone_earn)
        @test ismissing(zone_price)
        @test ismissing(first(earn_line.d[earn_line.d.zone .== "Total", :CCGT]))
        @test ismissing(first(price_line.d[price_line.d.zone .== "ZONE1", Symbol("Weighted average")]))
        @test Posy2._gensnapshotpp(s) isa AbstractDict
    end

    # No evalprice with foreign IC: selfcosts import/export/rent and aggregated Trade/Physical are missing.
    let
        sim = tsim()
        snap = Snapshot(sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; coeff=1.0)
        makedispatchable("CCGT", "CCGT", elec1, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", "CCGT", elec2, co2, snap; cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makenodeinterco("IC", elec1, elec2, 10_000.0, 10_000.0, snap; transactioncost=1.)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        @test isnothing(Nosy.dualprice(elec1))
        df = Posy2.selfcosts(s)
        cname = "IC_ZONE1_ZONE2"
        row = first(df[df[!, :component] .== cname, :])
        @test ismissing(row.imports)
        @test ismissing(row.exports)
        @test ismissing(row[Symbol("congestion rent")])
        agg = Posy2._dataline_costs_aggregated(s; showforeign=false)
        @test ismissing(agg.d["Trade"])
        @test ismissing(agg.d["Physical"])
        @test Posy2._gensnapshotpp(s) isa AbstractDict
    end
end
