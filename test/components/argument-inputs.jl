using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Argument and workbook input modes" begin
    function argument_snapshot(; tech=:arguments, series=:arguments)
        simulation = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
        set_silent(simulation.model)
        snapshot = Snapshot(simulation, Dict(:posy => Posy2Options(
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

    @testset "Dispatchable neutral defaults" begin
        let
            s, electricity, carbon = argument_snapshot()
            c = makedispatchable(
                "Neutral dispatchable", electricity, carbon, s; tech_column="unused", cap=10.0,
            )
            @test !isnothing(c)
            capacity_behavior = only(Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior))
            @test isnothing(capacity_behavior.data.unitsize)
            @test isempty(Nosy.getbehaviors(c, Nosy.RampingBehavior))
            @test all(iszero(b.data.val) for b in Nosy.getbehaviors(c, Nosy.FixedCostBehavior))
            @test all(iszero(b.data.val) for b in Nosy.getbehaviors(c, Nosy.VariableCostBehavior))
        end

        let
            s, electricity, carbon = argument_snapshot()
            fuel = Node("fuel", EnergyCarrier("fuel", sim(s)); rule=:curtailed)
            @test !isnothing(makedispatchable(
                "Lossless fuel", electricity, carbon, s; tech_column="unused",
                cap=10.0, fuelnode=fuel,
            ))
        end

        let
            s, electricity, carbon = argument_snapshot()
            c = makedispatchable(
                "Neutral UC", electricity, carbon, s; tech_column="unused",
                cap=10.0, unit_size=10.0, uc=true,
            )
            @test !isnothing(c)
            @test !isempty(Nosy.getbehaviors(c, Nosy.AbstractUnitCommitmentBehavior))
            @test isempty(Nosy.getbehaviors(c, Nosy.RampingBehavior))
        end

        let
            s, electricity, carbon = argument_snapshot()
            err = try
                makedispatchable(
                    "UC without units", electricity, carbon, s; tech_column="unused",
                    cap=10.0, unit_size=nothing, uc=true,
                )
                nothing
            catch caught
                caught
            end
            @test err isa ArgumentError
            @test occursin("unit_size", sprint(showerror, err))

            err = try
                makedispatchable(
                    "Ramp without units", electricity, carbon, s; tech_column="unused",
                    cap=10.0, unit_size=nothing, ramp_up=0.5,
                )
                nothing
            catch caught
                caught
            end
            @test err isa ArgumentError
            @test occursin("unit_size", sprint(showerror, err))
        end

        let
            s, electricity, carbon = argument_snapshot()
            err = try
                makedispatchable(
                    "Missing lifetime", electricity, carbon, s; tech_column="unused",
                    cap=10.0, overnight_cost=1_000.0,
                )
                nothing
            catch caught
                caught
            end
            @test err isa ArgumentError
            @test occursin("lifetime", sprint(showerror, err))

            err = try
                makedispatchable(
                    "Missing construction profile", electricity, carbon, s; tech_column="unused",
                    cap=10.0, overnight_cost=1_000.0, lifetime=30,
                )
                nothing
            catch caught
                caught
            end
            @test err isa ArgumentError
            @test occursin("construction_profile", sprint(showerror, err))

            @test !isnothing(makedispatchable(
                "No decommissioning", electricity, carbon, s;
                cap=10.0, overnight_cost=1_000.0, lifetime=30,
                construction_profile=1.0,
            ))
        end

        let
            s, electricity, carbon = argument_snapshot()
            err = try
                makedispatchable(
                    "Missing decommissioning profile", electricity, carbon, s; tech_column="unused",
                    cap=10.0, overnight_cost=1_000.0, lifetime=30,
                    construction_profile=1.0, decommissioning=0.1,
                )
                nothing
            catch caught
                caught
            end
            @test err isa ArgumentError
            @test occursin("decommissioning_profile", sprint(showerror, err))
        end
    end

    @testset "Neutral defaults for remaining builders" begin
        let
            s, electricity, carbon = argument_snapshot()
            hydrogen = Node("H2", EnergyCarrier("hydrogen", sim(s)); rule=:curtailed, tags=[:hydrogen])

            nuclear = makenuclear("Neutral nuclear", electricity, carbon, s; cap=10.0)
            battery = makebatterystorage("Neutral battery", electricity, s; duration=4.0)
            h2_storage = makehydrogenstorage("Neutral H2 storage", hydrogen, s)
            electrolyser = makeelectrolyser("Neutral electrolyser", electricity, hydrogen, s)

            for component in (nuclear, battery, h2_storage, electrolyser)
                @test !isnothing(component)
                @test all(iszero(b.data.val) for b in Nosy.getbehaviors(component, Nosy.FixedCostBehavior))
                @test all(iszero(b.data.val) for b in Nosy.getbehaviors(component, Nosy.VariableCostBehavior))
            end
            @test isempty(Nosy.getbehaviors(nuclear, Nosy.RampingBehavior))

            sized_nuclear = makenuclear(
                "Neutral sized nuclear", electricity, carbon, s; tech_column="unused",
                cap=10.0, unit_size=5.0,
            )
            @test isempty(Nosy.getbehaviors(sized_nuclear, Nosy.RampingBehavior))

            ramped_nuclear = makenuclear(
                "Ramped nuclear", electricity, carbon, s; tech_column="unused",
                cap=10.0, unit_size=5.0, ramp_up=0.2, ramp_down=0.3,
            )
            ramping = Nosy.getbehaviors(ramped_nuclear, Nosy.RampingBehavior)
            @test length(ramping) == 2
            up = only(filter(b -> b.data.sense == :up, ramping))
            down = only(filter(b -> b.data.sense == :down, ramping))
            @test up.data.val == 0.2 * 5.0
            @test down.data.val == 0.3 * 5.0

            @test_throws ArgumentError makenuclear(
                "Nuclear ramp without units", electricity, carbon, s; tech_column="unused",
                cap=10.0, ramp_up=0.2,
            )
        end

        let
            s, electricity, _ = argument_snapshot()
            ev = makeEV(
                "Neutral EV", electricity, s;
                number_ev=1_000.0,
                initial_connected_share=1.0,
                fixed_profile=false, smart_charging=true,
                departures=repeat(collect(1.0:24.0), 365), arrivals=repeat(collect(1.0:24.0), 365),
                departure_soc=0.8, arrival_soc=0.56,
                max_charging_power_per_ev=0.01,
                battery_capacity_per_ev=0.06,
            )
            @test !isnothing(ev)
            @test_throws ArgumentError makeEV(
                "Missing departure", electricity, s;
                number_ev=1_000.0,
                initial_connected_share=1.0,
                fixed_profile=false, smart_charging=true,
                arrivals=0.0, arrival_soc=0.56, departure_soc=0.8,
                max_charging_power_per_ev=0.01,
                battery_capacity_per_ev=0.06,
            )
            @test_throws ArgumentError makeEV(
                "Missing arrival", electricity, s;
                number_ev=1_000.0,
                initial_connected_share=1.0,
                fixed_profile=false, smart_charging=true,
                departures=1.0, departure_soc=0.8, arrival_soc=0.56,
                max_charging_power_per_ev=0.01,
                battery_capacity_per_ev=0.06,
            )
        end

        let
            s, electricity, _ = argument_snapshot()
            @test !isnothing(makepricelink("inactive", electricity, s; import_capacity=0.0, export_capacity=0.0))
        end

        let
            s, electricity, _ = argument_snapshot()
            @test !isnothing(makepricelink(
                "active", electricity, s;
                import_capacity=10.0, export_capacity=0.0, spot_price=50.0,
            ))
        end

        let
            s, electricity, _ = argument_snapshot()
            @test_throws ArgumentError makepricelink("active", electricity, s; import_capacity=10.0, export_capacity=0.0)
        end

        let
            s, electricity, _ = argument_snapshot()
            other = Node(
                "country2", EnergyCarrier("electricity country2", sim(s));
                rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
            )
            @test !isnothing(maketransmissionlink("Inactive", electricity, other, s; cap=0.0))
        end

        let
            s, electricity, _ = argument_snapshot()
            other = Node(
                "country2", EnergyCarrier("electricity country2", sim(s));
                rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
            )
            @test !isnothing(maketransmissionlink(
                "Active", electricity, other, s; cap=10.0, btoa_availability=0.0,
            ))
        end
    end

    # Every profile-backed builder can now run without either workbook.
    let
        s, electricity, carbon = argument_snapshot()
        @test !isnothing(makedemand(
            "Demand", "unused", electricity, s; profile=repeat(collect(40.0:63.0), 365),
        ))
        @test !isnothing(makeintermittentsource(
            "Solar", electricity, carbon, s;
            cap=80.0, profile=0.42, intermittent_costs...,
        ))
        @test !isnothing(makehydroror(
            "Hydro ROR", "unused", electricity, s;
            cap=70.0, intake=840.0, intake_profile=fill(35.0, 8760), hydro_costs...,
        ))
        @test !isnothing(makehydroreservoir(
            "Reservoir", "unused", electricity, s;
            discharge_cap=55.0, charge_cap=20.0, intake=240.0,
            energy_cap=200.0,
            intake_profile=repeat(collect(1.0:24.0), 365), roundtrip_eff=0.88, hydro_costs...,
        ))
        @test !isnothing(makeEV(
            "EV", electricity, s;
            number_ev=1_000.0,
            initial_connected_share=0.75,
            fixed_profile=false, smart_charging=true,
            departures=repeat(collect(1.0:24.0), 365), arrivals=repeat(collect(1.0:24.0), 365),
            departure_soc=0.8, arrival_soc=0.56,
            charging_eff=0.9, self_discharge=0.0,
            max_charging_power_per_ev=0.01,
            battery_capacity_per_ev=0.06,
        ))
    end

    let
        s, electricity, _ = argument_snapshot()
        other = Node(
            "country2", EnergyCarrier("electricity country2", sim(s));
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        @test !isnothing(makepricelink(
            "country2", electricity, s;
            import_capacity=100.0, export_capacity=80.0,
            spot_price=repeat(collect(51.0:74.0), 365),
            import_availability=0.9, export_availability=fill(0.85, 8760),
        ))
        @test !isnothing(maketransmissionlink(
            "Line", electricity, other, s; cap=70.0,
            atob_availability=0.95, btoa_availability=fill(0.8, 8760),
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
        @test !isnothing(makeintermittentsource(
            "Solar", electricity, carbon, s; tech_column="unused", cap=80.0, profile=0.42,
        ))
    end

    # The two switches are independent: one source can be workbook-backed and the other arguments.
    let
        simulation = Sim(Model(HiGHS.Optimizer))
        set_silent(simulation.model)
        data_dir = joinpath(dirname(@__DIR__), "data")
        electricity = Node(
            "ZONE1", EnergyCarrier("electricity ZONE1", simulation);
            rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
        )
        carbon = Node("CO2", CO2Carrier("CO2", simulation); rule=:curtailed, tags=[:co2])

        tech_excel = Snapshot(simulation, Dict(:posy => Posy2Options(
            data_dir=data_dir,
            techdata_file="tech_data_test.xlsx",
            timeseries_file="unused.xlsx",
            tech_mode=:excel,
            timeseries_mode=:arguments,
        )))
        @test !isnothing(makeintermittentsource(
            "Mixed", electricity, carbon, tech_excel; tech_column="Onwind",
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

        series_excel = Snapshot(simulation, Dict(:posy => Posy2Options(
            data_dir=data_dir,
            techdata_file="unused.xlsx",
            timeseries_file="time_series_test.xlsx",
            tech_mode=:arguments,
            timeseries_mode=:excel,
        )))
        @test !isnothing(makeintermittentsource(
            "Mixed reverse", electricity, carbon, series_excel; tech_column="Onwind",
            cap=10.0, weather_year=2019, intermittent_costs...,
        ))
    end
end
