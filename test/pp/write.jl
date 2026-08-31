using Posy2
using Nosy
using Test
using JuMP
using HiGHS
using XLSX
using DataFrames

@testset "Post processing write" begin
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

    # Full PP bundle: four report sections (annual self/all, time series, price curves) with expected types.
    let
        snap, elec1, elec2, co2 = makesnapshot()
        h2 = Node("H2", EnergyCarrier("hydrogen", sim(snap)), rule=:curtailed, tags=[:hydrogen])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makeEV(
            "EV", elec1, snap;
            annual_consumption=1000.0,
            fixed_profile=true, smart_charging=false, vehicle_to_grid=false,
            offhours1=[0, 1], offhours2=[2, 3], minratio=0.2,
        )
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

        dat = Posy2._gensnapshotpp(s)
        @test haskey(dat, "Annual values (all)")
        @test haskey(dat, "Annual values (self)")
        @test haskey(dat, "Losses")
        @test haskey(dat, "Time series")
        @test haskey(dat, "Price duration curves")
        @test dat["Losses"] isa AbstractVector
        @test dat["Time series"] isa DataFrame
        @test dat["Price duration curves"] isa DataFrame
        @test dat["Annual values (self)"] isa AbstractVector
        @test dat["Annual values (all)"] isa AbstractVector
    end

    # Workbook writer for DataFrame DataLines: missing cells are written as missing, not zero.
    let
        df = DataFrame(
            "From \\ To" => ["ZONE1 >", "ZONE2 >"],
            "> ZONE1" => [1.0, missing],
            "> ZONE2" => [missing, 2.0],
        )
        line = Posy2.DataLine("IC volume", "TWh/y", df)
        filepath = joinpath(mktempdir(), "pp_write_missing.xlsx")
        XLSX.openxlsx(filepath, mode="w") do xf
            sh = xf[1]
            Posy2.__write_to_sheet!(sh, line)
            @test sh[4, 2] == 1.0
            @test ismissing(sh[5, 2])
            @test ismissing(sh[4, 3])
            @test sh[5, 3] == 2.0
        end
    end

    # Workbook writer for dict DataLines: float values are rounded to three decimals.
    let
        line = Posy2.DataLine("Costs", "B USD", Dict("Physical" => 1.23456, "Trade" => 2.0))
        filepath = joinpath(mktempdir(), "pp_write_dict.xlsx")
        XLSX.openxlsx(filepath, mode="w") do xf
            sh = xf[1]
            Posy2.__write_to_sheet!(sh, line)
            @test sh[3, 1] == "Physical"
            @test sh[4, 1] == 1.235
            @test sh[3, 2] == "Trade"
            @test sh[4, 2] == 2.0
        end
    end

    # _write_results writes an xlsx with the four named sheets in order.
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

        dat = Posy2._gensnapshotpp(s)
        filepath = joinpath(mktempdir(), "pp_snapshot.xlsx")
        Posy2._write_results(dat, filepath)
        @test isfile(filepath)
        XLSX.openxlsx(filepath) do xf
            @test XLSX.sheetnames(xf) == [
                "Annual values (all)",
                "Annual values (self)",
                "Losses",
                "Time series",
                "Price duration curves",
            ]
        end
    end

    # Full export with one self node and one :foreign electricity node linked by a node IC:
    # all four report sections build (time series includes ATC columns) and the xlsx write succeeds.
    let
        _sim = tsim()
        snap = Snapshot(_sim, posyopts())
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", _sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity, :foreign])
        co2 = Node("CO2", CO2Carrier("CO2", _sim), rule=:curtailed, tags=[:co2])
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=50.0, construction_profile=1.0, decommissioning_profile=1.0)
        makedispatchable("CCGT", elec2, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        maketransmissionlink("IC", elec1, elec2, snap; cap=10_000.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        dat = Posy2._gensnapshotpp(s)
        ts = dat["Time series"]
        @test ts isa DataFrame
        @test "ATC ZONE1 > ZONE2" in names(ts)
        @test "ATC ZONE2 > ZONE1" in names(ts)

        filepath = joinpath(mktempdir(), "pp_foreign_node_ic.xlsx")
        Posy2._write_results(dat, filepath)
        @test isfile(filepath)
        XLSX.openxlsx(filepath) do xf
            @test XLSX.sheetnames(xf) == [
                "Annual values (all)",
                "Annual values (self)",
                "Losses",
                "Time series",
                "Price duration curves",
            ]
        end
    end

    # Full export with a fully disabled price IC (both directions zero): all report
    # sections build and the xlsx write succeeds.
    let
        snap, elec1, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makepricelink("ZONE2", elec1, snap; import_cap=0.0, export_cap=0.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        filepath = joinpath(mktempdir(), "pp_disabled_price_ic.xlsx")
        Posy2.write_results(s, filepath)
        @test isfile(filepath)
        XLSX.openxlsx(filepath) do xf
            @test XLSX.sheetnames(xf) == [
                "Annual values (all)",
                "Annual values (self)",
                "Losses",
                "Time series",
                "Price duration curves",
            ]
        end
    end

    # 2.11: a turbine-only reservoir keeps a zero-capacity input port, so the annual
    # charging column no longer throws a KeyError on the way through write_results.
    let
        snap, elec1, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        makehydroreservoir("Reservoir", "ZONE1", elec1, snap; tech_column="Battery",
            discharge_cap=50.0, charge_cap=0.0, intake=1_000.0,
            intake_profile=1.0, grid_losses=0.0, roundtrip_eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0, decommissioning=0.0,
        )
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        filepath = joinpath(mktempdir(), "pp_turbine_only_reservoir.xlsx")
        Posy2.write_results(s, filepath)
        @test isfile(filepath)
    end

    # write_results writes at the given path, creating missing parent directories,
    # and returns it. An existing file is kept unless overwrite=true.
    let
        snap, elec1, _, co2 = makesnapshot()
        makedemand("Other consumption", "ZONE1", elec1, snap; profile_multiplier=1.0)
        makedispatchable("CCGT", elec1, snap; co2_node=co2, tech_column="CCGT", cap=300.0, construction_profile=1.0, decommissioning_profile=1.0)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)

        filepath = joinpath(mktempdir(), "nested", "pp_overwrite.xlsx")
        @test Posy2.write_results(s, filepath) == filepath
        @test isfile(filepath)

        # a second write refuses, and does not touch the file it refused to replace
        before = stat(filepath)
        @test_throws ArgumentError Posy2.write_results(s, filepath)
        @test stat(filepath).mtime == before.mtime

        @test Posy2.write_results(s, filepath, overwrite=true) == filepath
        XLSX.openxlsx(filepath) do xf
            @test first(XLSX.sheetnames(xf)) == "Annual values (all)"
        end
    end

    # write_results requires an optimized snapshot; unoptimized snapshot raises AssertionError.
    let
        snap = Snapshot(tsim(), posyopts())
        @test_throws AssertionError Posy2.write_results(snap, "should_fail.xlsx")
    end
end
