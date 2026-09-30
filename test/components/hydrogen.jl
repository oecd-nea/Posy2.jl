using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Hydrogen components" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        opts = Dict(
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
        snap = Snapshot(sim, opts)
        h2 = Node("H2", EnergyCarrier("hydrogen", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, h2
    end

    # A valid flat hydrogen purchase input should create and register the component.
    let
        s, h2 = makesnapshot()
        c = makeflathydrogenpurchase("H2 purchase", h2, 8760.0, s)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "H2 purchase H2") === c
        @test Nosy.hastag(c, :function, "purchase")
        @test Nosy.hastag(c, :function, "hydrogen")
    end

    # A negative purchase amount is invalid and fails before construction.
    let
        s, h2 = makesnapshot()
        @test_throws ArgumentError makeflathydrogenpurchase("H2 purchase", h2, -1.0, s)
        @test !Nosy.hascomponent(s, "H2 purchase H2")
    end

    function makesnapshot2()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        opts = Dict(
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
        snap = Snapshot(sim, opts)
        h2_a = Node("A", EnergyCarrier("hydrogen A", sim), rule=:curtailed, tags=[:hydrogen])
        h2_b = Node("B", EnergyCarrier("hydrogen B", sim), rule=:curtailed, tags=[:hydrogen])
        return snap, h2_a, h2_b
    end

    # The default creates one optimized capacity shared by both directions.
    let
        s, h2_a, h2_b = makesnapshot2()
        c = makehydrogentransport("H2 pipeline", h2_a, h2_b, s; maxcap=100.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "H2 pipeline_A_B") === c
        @test Nosy.hastag(c, :function, "transport")
        @test Nosy.hastag(c, :function, "hydrogen")
        @test sort(get(c.tags, :zone, String[])) == ["A", "B"]
        @test Nosy.hasport(c, "input2")
        @test Nosy.hasport(c, "hydrogen transport losses")
        capacities = Nosy.getbehaviors(c, Nosy.VariableCapacityBehavior)
        @test length(capacities) == 2
        byport = Dict(capacity.data.pname => capacity for capacity in capacities)
        @test byport["input"].data.expr === byport["input2"].data.expr
        zone_a_links = Nosy.getcomponents(s, "A"; with=[:function => "transport"])
        @test length(zone_a_links) == 1
        @test haskey(zone_a_links, "H2 pipeline_A_B")
    end

    # Validation failures occur before component or SOS construction.
    let
        s, h2_a, h2_b = makesnapshot2()
        model = sim(s).model

        function model_size()
            return (
                JuMP.num_variables(model),
                JuMP.num_constraints(model; count_variable_in_set_constraints=true),
                length(Nosy.getcomponents(s)),
            )
        end

        before = model_size()
        for loss_factor in (-0.1, 1.0, Inf, NaN)
            @test_throws ArgumentError makehydrogentransport(
                "Invalid loss", h2_a, h2_b, s;
                cap=10.0, exclusive_direction=true, loss_factor=loss_factor,
            )
            @test model_size() == before
        end

        @test_throws ArgumentError makehydrogentransport(
            "Self", h2_a, h2_a, s; cap=10.0, exclusive_direction=true,
        )
        @test model_size() == before

        @test_throws ArgumentError makehydrogentransport(
            "No elec", h2_a, h2_b, s; cap=10.0, electricity_coeff=0.1,
        )
        @test model_size() == before

        @test_throws ArgumentError makehydrogentransport(
            "No lifetime", h2_a, h2_b, s;
            cap=nothing, overnight_cost=100.0, construction_profile=1.0,
        )
        @test model_size() == before

        makehydrogentransport("H2 pipeline", h2_a, h2_b, s; cap=10.0)
        before_duplicate = model_size()
        @test_throws ArgumentError makehydrogentransport(
            "H2 pipeline", h2_a, h2_b, s; cap=10.0,
        )
        @test model_size() == before_duplicate
        @test !Nosy.hascomponent(s, "Self_A_A")
    end

    # electricity_coeff > 0 with only elec_a is allowed (b -> a needs no compressor elec).
    let
        s, h2_a, h2_b = makesnapshot2()
        elec = Node("E", EnergyCarrier("electricity", sim(s)), rule=:curtailed, tags=[:electricity])
        c = makehydrogentransport(
            "One sided", h2_a, h2_b, s;
            cap=10.0, electricity_coeff=0.1, elec_a=elec,
        )
        @test Nosy.hasport(c, "electricity_a")
        @test !Nosy.hasport(c, "electricity_b")
    end

    # Directional SOS construction keeps the second node argument intact.
    let
        s, h2_a, h2_b = makesnapshot2()
        c = makehydrogentransport("Directional", h2_a, h2_b, s;
            cap=100.0, exclusive_direction=true,
        )
        @test Nosy.getcomponent(s, "Directional_A_B") === c
    end

    # Compressor electricity ports are optional and connect to separate nodes.
    let
        s, h2_a, h2_b = makesnapshot2()
        elec_a = Node("EA", EnergyCarrier("electricity A", sim(s)), rule=:curtailed, tags=[:electricity])
        elec_b = Node("EB", EnergyCarrier("electricity B", sim(s)), rule=:curtailed, tags=[:electricity])
        plain = makehydrogentransport("Plain", h2_a, h2_b, s; cap=10.0)
        @test !Nosy.hasport(plain, "electricity_a")
        @test !Nosy.hasport(plain, "electricity_b")

        a_only = makehydrogentransport("A only", h2_a, h2_b, s;
            cap=10.0, electricity_coeff=2.0, elec_a=elec_a,
        )
        @test Nosy.hasport(a_only, "electricity_a")
        @test !Nosy.hasport(a_only, "electricity_b")
        @test haskey(Nosy.getcomponents(s, "EA"), "A only_A_B")

        both = makehydrogentransport("Both", h2_a, h2_b, s;
            cap=10.0, electricity_coeff=2.0, elec_a=elec_a, elec_b=elec_b,
        )
        @test Nosy.hasport(both, "electricity_a")
        @test Nosy.hasport(both, "electricity_b")
        @test haskey(Nosy.getcomponents(s, "EA"), "Both_A_B")
        @test haskey(Nosy.getcomponents(s, "EB"), "Both_A_B")
    end

    # Investment and fixed O&M coefficients are attached once to the shared capacity.
    let
        s, h2_a, h2_b = makesnapshot2()
        c = makehydrogentransport(
            "Costed", h2_a, h2_b, s;
            cap=100.0,
            overnight_cost=2.0,
            om_fixed_cost=3.0,
            lifetime=20,
            construction_profile=1.0,
        )
        fixed_costs = Nosy.getbehaviors(c, Nosy.FixedCostBehavior)
        investment = only(filter(b -> Nosy._costtype(b) == :investment, fixed_costs))
        fom = only(filter(b -> Nosy._costtype(b) == :fom, fixed_costs))
        @test investment.data.val == eac(2_000.0, 0.05, 20, 1.0)
        @test fom.data.val == 3_000.0
        @test all(b.data.pname == "input" for b in fixed_costs)
    end

    # cap=0 registers a zero capacity corridor with the usual cost behaviors.
    let
        s, h2_a, h2_b = makesnapshot2()
        c = makehydrogentransport(
            "Zero", h2_a, h2_b, s;
            cap=0.0,
            overnight_cost=2.0,
            om_fixed_cost=3.0,
            lifetime=20,
            construction_profile=1.0,
        )
        @test Nosy.getcomponent(s, "Zero_A_B") === c
        capacities = Nosy.getbehaviors(c, Nosy.FixedCapacityBehavior)
        byport = Dict(capacity.data.pname => capacity for capacity in capacities)
        @test byport["input"].data.val == 0.0
        @test byport["input2"].data.val == 0.0
        @test length(Nosy.getbehaviors(c, Nosy.FixedCostBehavior)) == 2
    end

    # Electricity consumption on a -> b is proportional to the hydrogen send flow.
    let
        s, h2_a, h2_b = makesnapshot2()
        elec = Node("E", EnergyCarrier("electricity", sim(s)), rule=:curtailed, tags=[:electricity])
        elec_supply = Component(
            "Electricity supply E",
            ProfileSource(elec.carrier, 1.),
            [FixedCapacity("output", energy, 10_000.0)],
        )
        connect!(s, elec_supply, elec)
        makeflathydrogenpurchase("Supply", h2_a, 876_000.0, s)
        makeflathydrogendemand("Demand", h2_b, 5.0 * 8760.0, s)
        link = makehydrogentransport("H2 pipeline", h2_a, h2_b, s;
            cap=5.0, electricity_coeff=2.0, elec_a=elec,
        )
        Nosy.optimize!(s, cost(s))
        inputs = balance(link, :input, energy; collapse=false, aggregate=false)
        send = inputs["input"]
        electricity = inputs["electricity_a"]
        @test all(JuMP.value.(send) .== 5.0)
        @test all(JuMP.value.(electricity) .== 10.0)
    end
end