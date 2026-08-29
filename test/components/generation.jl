using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Generation components" begin
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
        co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])
        return snap, elec, co2
    end

    # cap=0 registers a zero-capacity component, like every other builder.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT", "CCGT", elec, co2, s;
            cap=0.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "CCGT ZONE1") === c
        @test only(Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior)).data.val == 0.0
    end

    # A valid dispatchable input should create and register the component.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable("CCGT", "CCGT", elec, co2, s; cap=100.0, construction_profile=1.0, decommissioning_profile=1.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "CCGT ZONE1") === c
        capacity_behavior = only(Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior))
        workbook_unit_size = gettechparam(s, "CCGT", "unit_size", "dispatchable")
        if iszero(workbook_unit_size)
            @test isnothing(capacity_behavior.data.unitsize)
        else
            @test capacity_behavior.data.unitsize == workbook_unit_size
        end
    end

    # Zero overrides the workbook unit size and is passed to Nosy as nothing.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT continuous", "CCGT", elec, co2, s;
            cap=100.0, unit_size=0.0,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        capacity_behavior = only(Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior))
        @test isnothing(capacity_behavior.data.unitsize)
        @test isempty(Nosy.getbehaviors(c, Nosy.RampingBehavior))
    end

    # If refuelling is enabled, a missing refuelmask should be rejected.
    let
        s, elec, co2 = makesnapshot()
        @test_throws ArgumentError makenuclear(
            "Nuclear", "CCGT", elec, co2, s;
            uc=true, cap=100.0,
            overnight_cost=1000.0, om_fixed_cost=10.0, om_var_cost=2.0,
            decommissioning=0.1, lifetime=30, construction_profile=1.0, decommissioning_profile=1.0,
            connection_cost=0.0, fuel_cost=30.0, waste_cost=0.0,
            no_load_cost=0.0, startup_cost=0.0,
            co2_emission=0.0, unit_size=0.0,
            min_power=0.3, min_uptime=1, min_downtime=1,
            startup_duration=1, shutdown_duration=1,
            refuel_fraction_per_year=0.2, refuel_duration=12, refuelmask=nothing,
        )
    end

    # Refuelling applies independently of the technology data column.
    let
        s, elec, co2 = makesnapshot()
        c = makenuclear(
            "Generic refuelling", "CCGT", elec, co2, s;
            uc=true, cap=100.0, unit_size=100.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0, connection_cost=0.0, fuel_cost=0.0,
            waste_cost=0.0, no_load_cost=0.0, startup_cost=0.0,
            co2_emission=0.0, ramp_up=0.0, ramp_down=0.0,
            min_power=0.3, min_uptime=1, min_downtime=1,
            startup_duration=1, shutdown_duration=1,
            refuel_fraction_per_year=0.2, refuel_duration=12, refuelmask=12,
        )
        ucb = only(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        @test length(ucb.shutdownselector) == 2
        refuel_shutdown = ucb.shutdownselector[2][2]
        @test refuel_shutdown isa GenericAffExpr
        @test is_fixed(first(refuel_shutdown.terms)[1])
    end

    # The master switch skips refuelling parameters and builds ordinary UC.
    let
        s, elec, co2 = makesnapshot(hours=24)
        c = makenuclear(
            "Refuelling disabled", "CCGT", elec, co2, s;
            uc=true, cap=100.0, unit_size=100.0, refuel=false,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0, connection_cost=0.0, fuel_cost=0.0,
            waste_cost=0.0, no_load_cost=0.0, startup_cost=0.0,
            co2_emission=0.0, ramp_up=0.0, ramp_down=0.0,
            min_power=0.3, min_uptime=1, min_downtime=1,
            startup_duration=1, shutdown_duration=1,
            refuel_fraction_per_year=0.2, refuel_duration=12, refuelmask=nothing,
        )
        ucb = only(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        @test length(ucb.shutdownselector) == 1
    end

    # Run of river can optimize output capacity within explicit bounds.
    let
        s, elec, _ = makesnapshot(hours=24)
        c = makehydroror(
            "Hydro ROR variable", "ZONE1", elec, s;
            cap=nothing, mincap=10.0, maxcap=100.0,
            intake=1_000.0, intake_profile=collect(1.0:24.0),
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        capacity_behavior = only(Nosy.getbehaviors(c, Nosy.VariableCapacityBehavior))
        @test capacity_behavior.data.lb == 10.0
        @test capacity_behavior.data.ub == 100.0

        shared_capacity = @variable(Nosy.uppermodel(sim(s)), lower_bound=0.0)
        linked = makehydroror(
            "Hydro ROR linked", "ZONE1", elec, s;
            cap=shared_capacity, mincap=5.0, maxcap=90.0,
            intake=1_000.0, intake_profile=collect(24.0:-1.0:1.0),
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        linked_behavior = only(Nosy.getbehaviors(linked, Nosy.VariableCapacityBehavior))
        @test linked_behavior.data.expr === shared_capacity

        capacity_expression = 2.0 * shared_capacity + 5.0
        affine = makehydroror(
            "Hydro ROR affine", "ZONE1", elec, s;
            cap=capacity_expression, mincap=5.0, maxcap=95.0,
            intake=1_000.0, intake_profile=collect(1.0:24.0),
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        )
        affine_behavior = only(Nosy.getbehaviors(affine, Nosy.VariableCapacityBehavior))
        @test affine_behavior.data.expr == capacity_expression
    end

    # Run-of-river profiles describe only the intake shape. Scaling a profile
    # must not change the distributed total intake.
    let
        s, elec, _ = makesnapshot(hours=24)
        profile = collect(1.0:24.0)
        total_intake = 1_000.0
        c = makehydroror(
            "Hydro ROR normalized", "ZONE1", elec, s;
            cap=500.0, intake=total_intake,
            intake_profile=profile,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=-1.0,
            decommissioning=0.0,
        )
        Nosy.optimize!(s, cost(s))
        result = extract(s)
        normalized = balance(
            Nosy.getcomponent(result, "Hydro ROR normalized ZONE1"),
            :output, energy; collapse=false, aggregate=true,
        )
        @test normalized ≈ profile / sum(profile) * total_intake
        @test sum(normalized) ≈ total_intake

        s2, elec2, _ = makesnapshot(hours=24)
        c2 = makehydroror(
            "Hydro ROR rescaled", "ZONE1", elec2, s2;
            cap=500.0, intake=total_intake,
            intake_profile=10 .* profile,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=-1.0,
            decommissioning=0.0,
        )
        Nosy.optimize!(s2, cost(s2))
        result2 = extract(s2)
        rescaled = balance(
            Nosy.getcomponent(result2, "Hydro ROR rescaled ZONE1"),
            :output, energy; collapse=false, aggregate=true,
        )
        @test rescaled ≈ normalized
    end

    # A profile with no intake cannot be normalized.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makehydroror(
            "Hydro ROR zero profile", "ZONE1", elec, s;
            cap=100.0, intake=100.0, intake_profile=0.0,
        )
    end

    # An intake shape is a physical flow and cannot run backwards.
    let
        s, elec, _ = makesnapshot(hours=24)
        @test_throws ArgumentError makehydroror(
            "Hydro ROR negative profile", "ZONE1", elec, s;
            cap=100.0, intake=100.0, intake_profile=vcat(-1.0, fill(2.0, 23)),
        )
    end

    # An intermittent profile is a capacity factor, so it stays within [0, 1].
    let
        s, elec, co2 = makesnapshot(hours=24)
        @test_throws ArgumentError makeintermittentsource(
            "Onwind above one", "Onwind", elec, co2, s;
            cap=100.0, profile=vcat(1.2, fill(0.3, 23)),
        )
        @test_throws ArgumentError makeintermittentsource(
            "Onwind negative", "Onwind", elec, co2, s;
            cap=100.0, profile=vcat(-0.1, fill(0.3, 23)),
        )
        @test !isnothing(makeintermittentsource(
            "Onwind valid", "Onwind", elec, co2, s;
            cap=100.0, profile=1.0, construction_profile=1.0, decommissioning_profile=1.0,
        ))
    end

    # Zero intake does not require a profile or weather year.
    let
        s, elec, _ = makesnapshot(hours=24)
        @test !isnothing(makehydroror(
            "Hydro ROR zero intake", "ZONE1", elec, s;
            cap=100.0, intake=0.0,
            overnight_cost=0.0, om_fixed_cost=0.0, om_var_cost=0.0,
            decommissioning=0.0,
        ))
    end

    # Generation capacity inputs accept real values or nothing, never complex values.
    let
        s, elec, co2 = makesnapshot()
        @test_throws TypeError makenuclear("Nuclear", "CCGT", elec, co2, s; cap=1 + im)
        @test_throws TypeError makeintermittentsource("Wind", "Onwind", elec, co2, s; cap=1 + im)
        @test_throws TypeError makeintermittentsource("Wind", "Onwind", elec, co2, s; mincap=1 + im)
    end

    # A valid intermittent source input should create and register the component.
    let
        s, elec, co2 = makesnapshot()
        c = makeintermittentsource("Onwind gen", "Onwind", elec, co2, s; cap=100.0, weatheryear=2019, construction_profile=1.0, decommissioning_profile=1.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "Onwind gen ZONE1") === c
        @test Nosy.hastag(c, :function, "carbonfree")
    end

    # Weather-indexed workbook profiles require an explicit year.
    let
        s, elec, co2 = makesnapshot()
        @test_throws ArgumentError makeintermittentsource(
            "Wind missing year", "Onwind", elec, co2, s;
            cap=100.0, construction_profile=1.0, decommissioning_profile=1.0,
        )
    end
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makehydroror(
            "Hydro ROR missing year", "ZONE1", elec, s;
            cap=100.0, intake=1_000.0,
        )
    end

    # An intermittent source with direct emissions must not be tagged carbon-free.
    let
        s, elec, co2 = makesnapshot()
        c = makeintermittentsource(
            "Emitting intermittent", "Onwind", elec, co2, s;
            cap=100.0, weatheryear=2019, co2_emission=100.0,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        @test Nosy.hastag(c, :function, "generation")
        @test Nosy.hastag(c, :function, "intermittent")
        @test !Nosy.hastag(c, :function, "carbonfree")
    end

    # A non-zero fractional ramp requires a positive unit size.
    let
        s, elec, co2 = makesnapshot()
        @test_throws ArgumentError makedispatchable(
            "CCGT no ramp", "CCGT", elec, co2, s;
            cap=100.0, unit_size=0.0, ramp_up=0.5, ramp_down=0.5,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
    end

    # ramp_up and ramp_down are scaled by unit_size before passing to Nosy.
    let
        s, elec, co2 = makesnapshot()
        c = makedispatchable(
            "CCGT ramp", "CCGT", elec, co2, s;
            cap=8.0, unit_size=2.0, ramp_up=0.2, ramp_down=0.3,
            construction_profile=1.0, decommissioning_profile=1.0,
        )
        ramping = Nosy.getbehaviors(c, Nosy.RampingBehavior)
        @test length(ramping) == 2
        up = only(filter(b -> b.data.sense == :up, ramping))
        down = only(filter(b -> b.data.sense == :down, ramping))
        @test up.data.val == 0.2 * 2.0
        @test down.data.val == 0.3 * 2.0
    end

    # With integer UC and optimized capacity, bounds are aligned to whole units.
    let
        s, elec, co2 = makesnapshot(hours=24)
        c = makedispatchable(
            "CCGT integeruc bounds", "CCGT", elec, co2, s;
            cap=nothing, mincap=5.0, maxcap=11.0, unit_size=4.0,
            uc=true, integeruc=true,
            construction_profile=1.0, decommissioning_profile=1.0,
            min_power=0.3, min_uptime=1, min_downtime=1,
            startup_duration=1, shutdown_duration=1,
            no_load_cost=0.0, startup_cost=0.0, ramp_up=0.0, ramp_down=0.0,
        )
        capacity_behavior = only(Nosy.getbehaviors(c, Nosy.VariableCapacityBehavior))
        @test capacity_behavior.data.lb == 8.0
        @test capacity_behavior.data.ub == 8.0
    end
end
