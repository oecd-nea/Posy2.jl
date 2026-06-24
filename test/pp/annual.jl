using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Post processing annual" begin
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

    function makesnapshot_ic_cap()
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
        makenodeinterco("IC", elec1, elec2, 2_000.0, 3_000.0, snap)
        Nosy.optimize!(snap, cost(snap))
        return extract(snap)
    end

    # Aggregated self costs should satisfy Physical + Trade = Total.
    let
        s = makesnapshot()
        d = POSY2._dataline_costs_aggregated(s; showforeign=false)
        @test isapprox(d.d["Physical"] + d.d["Trade"], d.d["Total"]; rtol=1e-12)
        @test isapprox(POSY2.selfcost(s) / 1e9, d.d["Total"]; rtol=1e-12)
    end

    # Foreign import/export columns should be 0 when no foreign IC exists.
    let
        s = makesnapshot()
        for (k, _) in Nosy.getnodes(s, with=[:electricity], without=[:foreign])
            @test POSY2.imports_foreign(s, k; collapse=true) / 1e6 == 0.0
            @test POSY2.exports_foreign(s, k; collapse=true) / 1e6 == 0.0
        end
    end

    # Interconnection volume dataline should scale MWh to TWh/y.
    let
        s = makesnapshot()
        raw_mwh = 438_000.0
        line = POSY2._dataline_ic_vol_detailed(s)
        @test line.unit == "TWh/y"
        v = line.d[line.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        @test v ≈ raw_mwh / 1e6
    end

    # Interconnection capacity dataline should scale MW to GW.
    let
        s = makesnapshot_ic_cap()
        line = POSY2._dataline_ic_cap(s)
        @test line.unit == "GW"
        v = line.d[line.d[!, "From \\ To"] .== "ZONE1 >", "> ZONE2"][1]
        @test v ≈ 2.0
    end

    # Zero flow corridors should remain 0.0 in the annual matrix, not missing.
    let
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
        makenodeinterco("IC", elec1, elec2, Inf, Inf, snap)
        Nosy.optimize!(snap, cost(snap))
        s = extract(snap)
        line = POSY2._dataline_ic_vol_detailed(s)
        v = line.d[line.d[!, "From \\ To"] .== "ZONE2 >", "> ZONE1"][1]
        @test v == 0.0
        @test !ismissing(v)
    end

    # Total row in the interconnection volume dataline should sum populated cells.
    let
        s = makesnapshot()
        line = POSY2._dataline_ic_vol_detailed(s)
        df = line.d
        datacols = [name for name in names(df)[2:end] if name != "> Total"]
        total_row = df[df[!, "From \\ To"] .== "Total >", :]
        for col in datacols
            expected = sum(df[i, col] for i in 1:(size(df, 1) - 1) if !ismissing(df[i, col]))
            @test total_row[1, col] ≈ expected
        end
    end
end
