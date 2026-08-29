using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Demand components" begin
    function makesnapshot(; losses=0.0)
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        opts = Dict(
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
        snap = Snapshot(sim, opts)
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=losses, tags=[:electricity])
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, elec, h2
    end

    # Demand should fail when coeff is negative.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makedemand("Demand", "ZONE1", elec, s; coeff=-1.0)
    end

    # A valid demand input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makedemand("Demand", "ZONE1", elec, s; coeff=1.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Demand ZONE1") === c
    end

    # Flat hydrogen demand should fail when val is negative.
    let
        s, _, h2 = makesnapshot()
        @test_throws ArgumentError makeflathydrogendemand("H2 demand", h2, -10.0, s)
    end

    # A valid flexible hydrogen demand input should create and register the component.
    let
        s, _, h2 = makesnapshot()
        c = makeflexhydrogendemand("H2 flex demand", h2, 1000.0, s)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "H2 flex demand H2") === c
    end

    # EV should fail when more than one mode is enabled.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            yearly=1000.0,
            fixed_profile=true, smart_charging=true, vehicle_to_grid=false,
            offhours1=[0, 1], offhours2=[2, 3], minratio=0.2,
        )
    end

    # EV fixed_profile should fail when required offhours/minratio inputs are missing.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            yearly=1000.0,
            fixed_profile=true, smart_charging=false, vehicle_to_grid=false,
            offhours1=nothing, offhours2=[2, 3], minratio=0.2,
        )
    end

    # EV smart-charging should fail when number_ev or initial_connected_share is missing.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            fixed_profile=false, smart_charging=true,
            departures=0.0, arrivals=0.0, departure_soc=0.8, arrival_soc=0.56,
            max_charging_power_per_ev=0.01, battery_capacity_per_ev=0.06,
        )
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            number_ev=1_000.0,
            fixed_profile=false, smart_charging=true,
            departures=0.0, arrivals=0.0, departure_soc=0.8, arrival_soc=0.56,
            max_charging_power_per_ev=0.01, battery_capacity_per_ev=0.06,
        )
    end

    # Fixed-profile EV reporting requires the same non-connected driving port as
    # smart-charging and vehicle-to-grid EVs.
    let
        s, elec, _ = makesnapshot()
        c = makeEV(
            "EV", elec, s;
            yearly=1000.0,
            fixed_profile=true, smart_charging=false, vehicle_to_grid=false,
            offhours1=[0, 1], offhours2=[2, 3], minratio=0.2,
        )
        @test Nosy.hasport(c, "driving")
    end

    # The fixed profile is normalized on the series that is actually generated,
    # so it consumes exactly `yearly` whatever the off-hour schedule is.
    let
        yearly = 1000.0
        schedules = (
            (offhours1=[0, 1], offhours2=[2, 3], minratio=0.2, days_threshold=104),
            (offhours1=Int[], offhours2=Int[], minratio=0.0, days_threshold=104),   # no off-hour
            (offhours1=collect(0:23), offhours2=collect(0:23), minratio=1.0, days_threshold=0),  # flat
            (offhours1=collect(0:22), offhours2=collect(0:22), minratio=0.0, days_threshold=183), # one hour a day
        )
        for schedule in schedules
            s, elec, _ = makesnapshot()
            c = makeEV("EV", elec, s; yearly=yearly, fixed_profile=true, schedule...)
            # a demand series is exogenous, so its balance is a constant
            consumed = JuMP.constant(Nosy.balance(c, :input, energy; collapse=true, aggregate=true))
            @test isapprox(consumed, yearly; rtol=1e-9)
        end
    end

    # Duplicate off-hours used to be counted twice in the normalization denominator.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            yearly=1000.0,
            fixed_profile=true, offhours1=[0, 0], offhours2=[2, 3], minratio=0.2,
        )
    end

    # A schedule with no charging hour at all has a zero denominator.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            yearly=1000.0,
            fixed_profile=true, offhours1=collect(0:23), offhours2=collect(0:23), minratio=0.0,
        )
    end

    # Charging efficiency applies when grid electricity enters the battery.
    # V2G, departure and arrival are already stored energy (eff = 1).
    let
        s, elec, _ = makesnapshot()
        c = makeEV(
            "EV", elec, s;
            number_ev=500.0,
            initial_connected_share=1.0,
            fixed_profile=false, smart_charging=false, vehicle_to_grid=true,
            departures=0.0, arrivals=0.0, departure_soc=0.8, arrival_soc=0.56,
            charging_eff=0.8, self_discharge=0.0,
            max_charging_power_per_ev=0.01, max_dispatch_power_per_ev=0.01,
            battery_capacity_per_ev=0.06,
        )

        @test c.model.data.eff["input"] == 0.8
        @test c.model.data.eff["output"] == 1.0
        @test c.model.data.eff["departure"] == 1.0
        @test c.model.data.eff["arrival"] == 1.0
        @test Nosy.hasport(c, "departure")
        @test Nosy.hasport(c, "arrival")
    end

    # Flexible EV rejects negative departure counts, invalid initial_connected_share, and unbalanced departures/arrivals.
    let
        flexible = (
            number_ev=1000.0,
            initial_connected_share=1.0,
            fixed_profile=false, smart_charging=true,
            charging_eff=0.9, self_discharge=0.0,
            max_charging_power_per_ev=0.01, battery_capacity_per_ev=0.06,
            departure_soc=0.8, arrival_soc=0.56,
        )
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            departures=vcat(-1.0, fill(0.0, 8759)), arrivals=0.0, flexible...,
        )
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            flexible...,
            initial_connected_share=1.5, departures=0.0, arrivals=0.0,
        )
        @test_throws ArgumentError makeEV(
            "EV", elec, s;
            departures=1.0, arrivals=0.0, flexible...,
        )
    end

    # After optimization, ten vehicles arriving at hour 2 raise fleet `level` (`level[3] > level[2]`).
    # The same mobility with a lower hour 2 `arrival_soc` leaves less stored energy at hour 3.
    let
        sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1 // 1, 24)))
        set_silent(sim.model)
        s = Snapshot(sim, Dict(:posy => Posy2Options(tech_mode=:arguments, timeseries_mode=:arguments)))
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim); rule=:curtailed, tags=[:co2])
        makeEV(
            "EV", elec, s;
            number_ev=100.0,
            initial_connected_share=0.75,
            fixed_profile=false, smart_charging=true,
            departures=vcat(zeros(2), 10.0, zeros(18), 10.0, zeros(2)),
            arrivals=vcat(zeros(1), 10.0, zeros(18), 10.0, zeros(3)),
            departure_soc=0.5,
            arrival_soc=vcat(zeros(1), 1.0, zeros(22)),
            charging_eff=1.0, self_discharge=0.0,
            max_charging_power_per_ev=0.01,
            battery_capacity_per_ev=0.06,
        )
        makedispatchable(
            "Supply", "CCGT", elec, co2, s;
            cap=100.0, fuel_cost=1_000.0, overnight_cost=0.0, co2_emission=0.0,
        )
        Nosy.optimize!(s, cost(s))
        @test is_solved_and_feasible(s.sim.model)
        result = extract(s)
        ev = Nosy.getcomponent(result, "EV ZONE1")
        high_arrival = balance(ev, :level, energy; collapse=false, aggregate=true)

        sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1 // 1, 24)))
        set_silent(sim.model)
        s = Snapshot(sim, Dict(:posy => Posy2Options(tech_mode=:arguments, timeseries_mode=:arguments)))
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        co2 = Node("CO2", CO2Carrier("CO2", sim); rule=:curtailed, tags=[:co2])
        makeEV(
            "EV", elec, s;
            number_ev=100.0,
            initial_connected_share=0.75,
            fixed_profile=false, smart_charging=true,
            departures=vcat(zeros(2), 10.0, zeros(18), 10.0, zeros(2)),
            arrivals=vcat(zeros(1), 10.0, zeros(18), 10.0, zeros(3)),
            departure_soc=0.5,
            arrival_soc=vcat(zeros(1), 0.5, zeros(22)),
            charging_eff=1.0, self_discharge=0.0,
            max_charging_power_per_ev=0.01,
            battery_capacity_per_ev=0.06,
        )
        makedispatchable(
            "Supply", "CCGT", elec, co2, s;
            cap=100.0, fuel_cost=1_000.0, overnight_cost=0.0, co2_emission=0.0,
        )
        Nosy.optimize!(s, cost(s))
        @test is_solved_and_feasible(s.sim.model)
        result = extract(s)
        ev = Nosy.getcomponent(result, "EV ZONE1")
        low_arrival = balance(ev, :level, energy; collapse=false, aggregate=true)

        @test high_arrival[3] > high_arrival[2]
        @test high_arrival[3] > low_arrival[3]
    end

    # Charging availability at hour t uses the connected fleet at the start of that hour.
    let
        s, elec, _ = makesnapshot()
        nh = Nosy.nhours(sim(s))
        dep = vcat(80.0, 20.0, zeros(nh - 2))
        arr = vcat(20.0, 80.0, zeros(nh - 2))
        c = makeEV(
            "EV", elec, s;
            number_ev=100.0,
            initial_connected_share=1.0,
            fixed_profile=false, smart_charging=true,
            departures=dep, arrivals=arr,
            departure_soc=1.0, arrival_soc=1.0,
            charging_eff=0.9, self_discharge=0.0,
            max_charging_power_per_ev=0.01,
            battery_capacity_per_ev=0.06,
        )
        mults = Dict(
            b.data.pname => b.val.data
            for b in Nosy.getbehaviors(c, Nosy.CapacityMultiplierBehavior)
        )
        @test mults["input"][1] == 1.0
        @test mults["input"][2] == 0.4
        @test mults["level"][1] == 1.0
        @test mults["level"][2] == 0.4
    end

    # A valid demand response input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makedemandresponse("DR", elec, 100.0, 50.0, s)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "DR ZONE1") === c
    end

    # Nothing creates a capacity decision.
    let
        s, elec, _ = makesnapshot()
        variable = @test_logs (
            :warn,
            "`cap=nothing` defines a variable demand response capacity. Use `cap=Inf` for unlimited capacity.",
        ) makedemandresponse("Variable DR", elec, nothing, 50.0, s)
        @test length(Nosy.getbehaviors(variable, Nosy.VariableCapacityBehavior)) == 1

        unlimited = @test_nowarn makedemandresponse("Unlimited DR", elec, Inf, 50.0, s)
        @test isempty(Nosy.getbehaviors(unlimited, Nosy.AbstractCapacityBehavior))
    end

    # Demand response keeps a positive output for reporting while connecting
    # its negative to the demand side of the electricity node.
    let
        s, elec, _ = makesnapshot()
        makedemand("Demand", "ZONE1", elec, s; coeff=1.0)
        c = makedemandresponse("DR", elec, 100.0, 50.0, s)

        @test Nosy.getcomponent(s, "DR ZONE1") === c
        @test Nosy.hasport(c, "output")
        @test Nosy.hasport(c, "negative consumption")

        Nosy.optimize!(s, cost(s))
        result = extract(s)
        dr = Nosy.getcomponent(result, "DR ZONE1")
        output = balance(dr, :output, energy; collapse=true, aggregate=true)
        inputs = balance(dr, :input, energy; collapse=true, aggregate=false)

        @test isapprox(output, 100.0 * 8760; rtol=1e-12)
        @test inputs["input"] == 0.0
        @test isapprox(inputs["negative consumption"], -output; rtol=1e-12)
        @test isapprox(Posy2.demandresponse(result, "ZONE1"), output; rtol=1e-12)
        @test isapprox(Posy2.demand(result, "ZONE1"; aggregate=true, collapse=true), 100.0 * 8760; rtol=1e-12)
    end

    # A 100 MW delivered response requires 125 MW activation when node losses
    # are 20%, while cost applies to the full positive activation output.
    let
        s, elec, _ = makesnapshot(losses=0.2)
        makedemand("Demand", "ZONE1", elec, s; coeff=1.0)
        makedemandresponse("DR", elec, 125.0, 50.0, s)
        Nosy.optimize!(s, cost(s))
        result = extract(s)
        output = Posy2.demandresponse(result, "ZONE1")

        @test isapprox(output, 125.0 * 8760; rtol=1e-12)
        @test isapprox(cost(result), 50.0 * 125.0 * 8760; rtol=1e-12)
    end
end
