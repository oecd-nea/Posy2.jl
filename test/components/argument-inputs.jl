using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Argument and Excel input modes" begin
    function argument_snapshot(; hours=24, tech=:arguments, series=:arguments)
        simulation = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1 // 1, hours)))
        set_silent(simulation.model)
        snapshot = Snapshot(simulation, Dict(:posy => POSY2Options(
            data_dir=joinpath(@__DIR__, "does-not-exist"),
            techdata_file="does-not-exist.xlsx",
            timeseries_file="does-not-exist.xlsx",
            tech_mode=tech,
            timeseries_mode=series,
        )))
        electricity = Node(
            "country1", EnergyCarrier("electricity country1", simulation);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        carbon = Node("CO2", CO2Carrier("CO2", simulation); rule=:curtailed, tags=[:co2])
        return snapshot, electricity, carbon
    end

    generation_costs = (
        overnight_cost=1_100.0,
        om_fixed_cost=13.0,
        decommissioning=0.08,
        lifetime=32,
        construction_profile=1.0,
        decommissioning_profile=1.0,
        om_var_cost=2.5,
        fuel_cost=24.0,
        co2_emission=0.0,
    )
    intermittent_costs = merge(generation_costs, (connection_cost=0.04,))
    hydro_costs = (
        overnight_cost=1_700.0,
        om_fixed_cost=11.0,
        om_var_cost=1.2,
        decommissioning=0.07,
        lifetime=45,
        construction_profile=1.0,
        decommissioning_profile=1.0,
    )

    # Every profile-backed builder can now run without either workbook.
    let
        s, electricity, carbon = argument_snapshot()
        @test !isnothing(makedemand(
            "Demand", "unused", electricity, s; profile=collect(40.0:63.0),
        ))
        @test !isnothing(makeintermittentsource(
            "Solar", "unused", electricity, carbon, s;
            cap=80.0, profile=0.42, intermittent_costs...,
        ))
        @test !isnothing(POSY2.makenuclearprofile(
            "Nuclear profile", "unused", electricity, carbon, s;
            cap=90.0, profile=fill(0.81, 24), generation_costs...,
        ))
        @test !isnothing(makehydroror(
            "Hydro ROR", "unused", electricity, s;
            cap=70.0, inflow_profile=fill(35.0, 24), hydro_costs...,
        ))
        @test !isnothing(POSY2.makereservoirprofile(
            "Reservoir profile", "unused", electricity, s;
            cap=60.0, output_profile=fill(25.0, 24), hydro_costs...,
        ))
        @test !isnothing(makehydroreservoir(
            "Reservoir", "unused", "unused", electricity,
            55.0, 20.0, 200.0, 240.0, s;
            inflow_profile=collect(1.0:24.0), eff=0.88, hydro_costs...,
        ))
        @test !isnothing(makeEV(
            "EV", 2_400.0, electricity, s;
            fixed_profile=false, smart_charging=true,
            charging_availability=fill(0.75, 24), driving_profile=collect(1.0:24.0),
            charging_eff=0.9, self_discharge=0.0, min_level_morning=0.2,
            max_charging_power_per_ev=0.01, max_dispatch_power_per_ev=0.0,
            battery_capacity_per_ev=0.06, yearly_consumption_per_ev=2.4,
        ))
    end

    let
        s, electricity, _ = argument_snapshot()
        other = Node(
            "country2", EnergyCarrier("electricity country2", sim(s));
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        @test !isnothing(makepriceinterco(
            "country2", electricity, 100.0, 80.0, s;
            spot_price=collect(51.0:74.0),
            import_availability=0.9, export_availability=fill(0.85, 24),
        ))
        @test !isnothing(makenodeinterco(
            "Line", electricity, other, 70.0, 60.0, s;
            atob_availability=0.95, btoa_availability=fill(0.8, 24),
        ))
    end

    # Argument mode fails at the missing value instead of attempting file I/O.
    let
        s, electricity, carbon = argument_snapshot()
        @test_throws ArgumentError makedemand("Demand", "unused", electricity, s)
        @test_throws ArgumentError makedemand(
            "Demand short", "unused", electricity, s; profile=fill(1.0, 23),
        )
        @test_throws ArgumentError makedemand(
            "Demand nonfinite", "unused", electricity, s;
            profile=vcat(fill(1.0, 23), Inf),
        )
        @test_throws ArgumentError makeintermittentsource(
            "Solar", "unused", electricity, carbon, s; cap=80.0, profile=0.42,
        )
    end

    # The two switches are independent: one source can be Excel and the other arguments.
    let
        simulation = Sim(Model(HiGHS.Optimizer))
        set_silent(simulation.model)
        data_dir = joinpath(dirname(@__DIR__), "data")
        electricity = Node(
            "ZONE1", EnergyCarrier("electricity ZONE1", simulation);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        carbon = Node("CO2", CO2Carrier("CO2", simulation); rule=:curtailed, tags=[:co2])

        tech_excel = Snapshot(simulation, Dict(:posy => POSY2Options(
            data_dir=data_dir,
            techdata_file="tech_data_test.xlsx",
            timeseries_file="unused.xlsx",
            tech_mode=:excel,
            timeseries_mode=:arguments,
        )))
        @test !isnothing(makeintermittentsource(
            "Mixed", "Onwind", electricity, carbon, tech_excel;
            cap=10.0, profile=0.5,
            construction_profile=1.0, decommissioning_profile=1.0,
        ))
    end

    let
        simulation = Sim(Model(HiGHS.Optimizer))
        set_silent(simulation.model)
        data_dir = joinpath(dirname(@__DIR__), "data")
        electricity = Node(
            "ZONE1", EnergyCarrier("electricity ZONE1", simulation);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        carbon = Node("CO2", CO2Carrier("CO2", simulation); rule=:curtailed, tags=[:co2])

        series_excel = Snapshot(simulation, Dict(:posy => POSY2Options(
            data_dir=data_dir,
            techdata_file="unused.xlsx",
            timeseries_file="time_series_test.xlsx",
            tech_mode=:arguments,
            timeseries_mode=:excel,
        )))
        @test !isnothing(makeintermittentsource(
            "Mixed reverse", "Onwind", electricity, carbon, series_excel;
            cap=10.0, weatheryear=2019, intermittent_costs...,
        ))
    end
end
