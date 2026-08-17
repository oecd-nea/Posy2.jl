using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Storage components" begin
    function makesnapshot(; hours=8760)
        sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1 // 1, hours)))
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
        elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, elec, h2
    end

    # Reservoir intake uses the same normalized-profile, scalar-intake, and
    # dimensionless-multiplier contract as run-of-river hydro.
    let
        s, elec, _ = makesnapshot(hours=24)
        profile = collect(1.0:24.0)
        total_intake = 1_000.0
        makehydroreservoir(
            "Normalized intake reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=500.0, cap_charging=0.0, intake=total_intake,
            cap_reservoir=2_000.0,
            intake_profile=profile,
            gridlosses=0.0, eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        Nosy.optimize!(s, cost(s))
        result = extract(s)
        actual = only(values(Posy2.intake(
            result; aggregate=false, collapse=false,
        )))
        expected = profile / sum(profile) * total_intake
        @test actual ≈ expected
        @test sum(actual) ≈ total_intake
    end

    # A natural inflow cannot run backwards, as for run-of-river hydro.
    let
        s, elec, _ = makesnapshot(hours=24)
        @test_throws ArgumentError makehydroreservoir(
            "Negative intake reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=500.0, cap_charging=0.0, intake=1_000.0,
            cap_reservoir=2_000.0,
            intake_profile=vcat(-1.0, fill(2.0, 23)),
            gridlosses=0.0, eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
    end

    # Battery duration should fail when it is zero.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makebatterystorage(
            "Battery", "Battery", elec, s;
            eff=0.9, duration=0.0,
            overnight_cost=1000.0, lifetime=20, construction_profile=1.0, decommissioning_profile=1.0,
        )
    end

    # Storage capacity inputs reject non-real numeric values at the API boundary.
    let
        s, elec, h2 = makesnapshot()
        @test_throws TypeError makebatterystorage("Battery", "Battery", elec, s; cap=1 + im)
        @test_throws TypeError makehydrogenstorage("H2 Storage", "Hydrogen storage", h2, s; cap=1 + im)
    end

    # A valid battery input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makebatterystorage(
            "Battery", "Battery", elec, s;
            cap=100.0,
            eff=0.9, duration=4.0,
            overnight_cost=1000.0, om_fixed_cost=10.0,
            decommissioning=0.1, lifetime=20.0, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, om_var_cost=1.0,
        )
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Battery ZONE1") === c
    end

    # Hydrogen storage should fail when efficiency is outside (0, 1].
    let
        s, _, h2 = makesnapshot()
        @test_throws ArgumentError makehydrogenstorage("H2 Storage", "Hydrogen storage", h2, s; eff=1.2)
    end

    # A valid hydro reservoir input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makehydroreservoir(
            "Hydro reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=50.0, intake=0.0,
            cap_reservoir=500.0,
            gridlosses=0.0, eff=0.9,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=1.0,
            decommissioning=0.1, lifetime=30.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Hydro reservoir ZONE1") === c
    end

    # Optimized pumping capacity creates its input flow before attaching the
    # variable capacity and optional grid-loss behaviors.
    for gridlosses in (0.0, 0.05)
        s, elec, _ = makesnapshot()
        c = makehydroreservoir(
            "Variable pumping reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=nothing, intake=0.0,
            cap_reservoir=500.0,
            gridlosses=gridlosses, eff=0.9,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        @test Nosy.hasport(c, "input")
        input_capacities = filter(
            b -> b.data.pname == "input",
            Nosy.getbehaviors(c, Nosy.VariableCapacityBehavior),
        )
        @test length(input_capacities) == 1
        @test Nosy.hasport(c, "grid losses") == !iszero(gridlosses)
    end

    # Reservoir level capacity follows the shared capacity API: finite is
    # fixed, `nothing` is optimized, and the default `Inf` is unlimited.
    let
        s, elec, _ = makesnapshot()
        common = (
            intake_profile=1.0, gridlosses=0.0, eff=0.9,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        fixed = makehydroreservoir(
            "Fixed reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=0.0, intake=8760.0,
            cap_reservoir=500.0, common...,
        )
        variable = makehydroreservoir(
            "Variable reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=0.0, intake=8760.0,
            cap_reservoir=nothing, common...,
        )
        unlimited = makehydroreservoir(
            "Unlimited reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=0.0, intake=8760.0, common...,
        )
        fixed_level_capacities = filter(
            b -> b.data.pname == "level",
            Nosy.getbehaviors(fixed, Nosy.FixedCapacityBehavior),
        )
        variable_level_capacities = filter(
            b -> b.data.pname == "level",
            Nosy.getbehaviors(variable, Nosy.VariableCapacityBehavior),
        )
        unlimited_fixed_capacities = filter(
            b -> b.data.pname == "level",
            Nosy.getbehaviors(unlimited, Nosy.FixedCapacityBehavior),
        )
        unlimited_variable_capacities = filter(
            b -> b.data.pname == "level",
            Nosy.getbehaviors(unlimited, Nosy.VariableCapacityBehavior),
        )

        @test length(fixed_level_capacities) == 1
        @test length(variable_level_capacities) == 1
        @test isempty(unlimited_fixed_capacities)
        @test isempty(unlimited_variable_capacities)
    end

    # Periodic storage forces all natural intake through the turbine, so an
    # overflowing reservoir is infeasible unless spillage is enabled. With
    # `spillage=true` the turbine saturates and the excess intake is spilled.
    let
        hours = 24
        turbine = 10.0
        total_intake = 1_000.0 # far above turbine * hours = 240
        common = (
            intake_profile=1.0, gridlosses=0.0, eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )

        s, elec, _ = makesnapshot(hours=hours)
        makehydroreservoir(
            "Overflowing reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=turbine, cap_charging=0.0, intake=total_intake, common...,
        )
        Nosy.optimize!(s, cost(s))
        @test !is_solved_and_feasible(s.sim.model)

        s, elec, _ = makesnapshot(hours=hours)
        # Flat demand at turbine capacity: the reservoir is the only supply, so
        # its output is pinned to the turbine rating in every hour.
        makedemand("Other consumption", "ZONE1", elec, s; profile=turbine)
        c = makehydroreservoir(
            "Overflowing reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=turbine, cap_charging=0.0, intake=total_intake,
            spillage=true, common...,
        )
        @test Nosy.hasport(c, "spill")
        Nosy.optimize!(s, cost(s))
        result = extract(s)
        @test is_solved_and_feasible(s.sim.model)

        rc = Nosy.getcomponent(result, "Overflowing reservoir ZONE1")
        generation = balance(rc, :output, energy, collapse=false, aggregate=false)["output"]
        spilled = only(values(Posy2.spillage(result; aggregate=false, collapse=false)))
        @test generation ≈ fill(turbine, hours)
        @test sum(spilled) ≈ total_intake - turbine * hours
        # Conservation over the periodic cycle: intake = generation + spillage.
        @test sum(generation) + sum(spilled) ≈ total_intake
    end

    # Spillage is opt-in: no spill port is created by default.
    let
        s, elec, _ = makesnapshot(hours=24)
        c = makehydroreservoir(
            "Default reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=0.0, intake=100.0,
            intake_profile=1.0, gridlosses=0.0, eff=1.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        @test !Nosy.hasport(c, "spill")
        @test isempty(Posy2.spillage(s; aggregate=false, collapse=false))
    end

    # A zero-sum intake profile cannot be normalized.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makehydroreservoir(
            "Zero intake reservoir", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=0.0, intake=1_000.0,
            cap_reservoir=500.0,
            intake_profile=0.0,
            gridlosses=0.0, eff=0.9,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=1.0,
            decommissioning=0.1, lifetime=30.0,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
    end

    # Workbook intake lookup requires an explicit weather year. Explicit
    # profiles do not, and are covered by the capacity cases above.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makehydroreservoir(
            "Missing weather year", "Battery", "ZONE1", elec, s;
            cap_discharging=100.0, cap_charging=0.0, intake=1_000.0,
            cap_reservoir=500.0, gridlosses=0.0, eff=0.9,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
    end
end
