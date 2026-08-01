using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Demand components" begin
    function makesnapshot(; losses=0.0)
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
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
            "EV", 1000.0, elec, s;
            fixed_profile=true, smart_charging=true, vehicle_to_grid=false,
            offhours1=[0, 1], offhours2=[2, 3], minratio=0.2,
        )
    end

    # EV fixed_profile should fail when required offhours/minratio inputs are missing.
    let
        s, elec, _ = makesnapshot()
        @test_throws ArgumentError makeEV(
            "EV", 1000.0, elec, s;
            fixed_profile=true, smart_charging=false, vehicle_to_grid=false,
            offhours1=nothing, offhours2=[2, 3], minratio=0.2,
        )
    end

    # Fixed-profile EV reporting requires the same non-connected driving port as
    # smart-charging and vehicle-to-grid EVs.
    let
        s, elec, _ = makesnapshot()
        c = makeEV(
            "EV", 1000.0, elec, s;
            fixed_profile=true, smart_charging=false, vehicle_to_grid=false,
            offhours1=[0, 1], offhours2=[2, 3], minratio=0.2,
        )
        @test Nosy.hasport(c, "driving")
    end

    # A valid demand response input should create and register the component.
    let
        s, elec, _ = makesnapshot()
        c = makedemandresponse("DR", elec, 100.0, 50.0, s)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "DR ZONE1") === c
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
        @test isapprox(POSY2.demandresponse(result, "ZONE1"), output; rtol=1e-12)
        @test isapprox(POSY2.demand(result, "ZONE1"; aggregate=true, collapse=true), 100.0 * 8760; rtol=1e-12)
    end

    # A 100 MW delivered response requires 125 MW activation when node losses
    # are 20%, while cost applies to the full positive activation output.
    let
        s, elec, _ = makesnapshot(losses=0.2)
        makedemand("Demand", "ZONE1", elec, s; coeff=1.0)
        makedemandresponse("DR", elec, 125.0, 50.0, s)
        Nosy.optimize!(s, cost(s))
        result = extract(s)
        output = POSY2.demandresponse(result, "ZONE1")

        @test isapprox(output, 125.0 * 8760; rtol=1e-12)
        @test isapprox(cost(result), 50.0 * 125.0 * 8760; rtol=1e-12)
    end
end
