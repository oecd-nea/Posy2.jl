using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "KVL" begin
    function makesnapshot(; dcopf::Bool=true)
        sim = Sim(Model(HiGHS.Optimizer), mesh=TimeMesh(fill(1//1, 24)))
        set_silent(sim.model)
        snap = Snapshot(sim, Dict(
            :posy => Posy2Options(
                data_dir=joinpath(@__DIR__, "..", "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
                tech_mode=:excel,
                timeseries_mode=:excel,
                dcopf=dcopf,
            ),
        ))
        return snap, sim
    end

    # Single AC link with no cycle: B-matrix has one edge, cycle basis is empty, and hourly source output matches demand.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])

        src = Component("src", DispatchableSource(n1.carrier), [VariableCost(:fuel, "output", energy, 1.0)])
        connect!(snap, src, n1)
        dmd = Component("dmd", Demand(n2.carrier, fill(1.0, 24)), [])
        connect!(snap, dmd, n2)

        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=-1.0)

        _, _, node_map = Posy2.getic_susceptancematrix(snap)
        @test length(node_map) == 1
        @test isempty(Posy2.gencycles(Posy2.getic_susceptancematrix(snap)[1]))

        @test_logs (:warn, r"No AC loops were found") Posy2.applydcopf!(snap)
        Nosy.optimize!(snap, cost(snap))
        @test is_solved_and_feasible(sim.model)

        ex = extract(snap)
        src_hourly = balance(ex, "src", :output, energy; collapse=false, aggregate=true)
        dmd_hourly = balance(ex, "dmd", :input, energy; collapse=false, aggregate=true)
        @test all(isapprox.(src_hourly.data, dmd_hourly.data; atol=1e-6))
    end

    # DC tagged node IC is omitted from getic_susceptancematrix; optimize remains feasible with power balance only.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])

        src = Component("src", DispatchableSource(n1.carrier), [VariableCost(:fuel, "output", energy, 1.0)])
        connect!(snap, src, n1)
        dmd = Component("dmd", Demand(n2.carrier, fill(1.0, 24)), [])
        connect!(snap, dmd, n2)

        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=true)

        mat, _, node_map = Posy2.getic_susceptancematrix(snap)
        @test isempty(node_map)
        @test all(iszero, mat)

        @test_logs (:warn, r"No AC loops were found") Posy2.applydcopf!(snap)
        Nosy.optimize!(snap, cost(snap))
        @test is_solved_and_feasible(sim.model)

        ex = extract(snap)
        src_hourly = balance(ex, "src", :output, energy; collapse=false, aggregate=true)
        dmd_hourly = balance(ex, "dmd", :input, energy; collapse=false, aggregate=true)
        @test all(isapprox.(src_hourly.data, dmd_hourly.data; atol=1e-6))
    end

    # Three node AC loop: sum(flow/B) is zero on the cycle, reverse net flow equals negated forward flow, and source covers both loads.
    let
        snap, sim = makesnapshot()

        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])

        src = Component("src", DispatchableSource(n1.carrier), [
            VariableCost(:fuel, "output", energy, 1.0),
            FixedCapacity("output", energy, 48.0),
        ])
        connect!(snap, src, n1)
        d2 = Component("dmd2", Demand(n2.carrier, fill(1.0, 24)), [])
        d3 = Component("dmd3", Demand(n3.carrier, fill(1.0, 24)), [])
        connect!(snap, d2, n2)
        connect!(snap, d3, n3)

        b12, b23, b31 = -1.5, -0.7, -2.0
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=b12)
        makenodeinterco("IC", n2, n3, Inf, Inf, snap; dc=false, susceptance=b23)
        makenodeinterco("IC", n3, n1, Inf, Inf, snap; dc=false, susceptance=b31)

        Posy2.applydcopf!(snap)
        Nosy.optimize!(snap, cost(snap))
        @test is_solved_and_feasible(sim.model)

        _, _, node_map = Posy2.getic_susceptancematrix(snap)
        f12 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE1", "ZONE2", node_map))
        f23 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE2", "ZONE3", node_map))
        f31 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE3", "ZONE1", node_map))
        lhs = f12 ./ b12 .+ f23 ./ b23 .+ f31 ./ b31
        @test all(isapprox.(lhs, 0.0; atol=1e-6))

        f21 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE2", "ZONE1", node_map))
        @test all(isapprox.(f21, .-f12; atol=1e-6))

        ex = extract(snap)
        src_hourly = balance(ex, "src", :output, energy; collapse=false, aggregate=true)
        dmd2_hourly = balance(ex, "dmd2", :input, energy; collapse=false, aggregate=true)
        dmd3_hourly = balance(ex, "dmd3", :input, energy; collapse=false, aggregate=true)
        @test all(isapprox.(src_hourly.data, dmd2_hourly.data .+ dmd3_hourly.data; atol=1e-6))
    end

    # Lossy AC loop: KVL uses midpoint flows, with half of each directional loss
    # deducted from its sending-end flow.
    let
        snap, sim = makesnapshot()

        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])

        src = Component("src", DispatchableSource(n1.carrier), [
            VariableCost(:fuel, "output", energy, 1.0),
            FixedCapacity("output", energy, 100.0),
        ])
        connect!(snap, src, n1)
        connect!(snap, Component("dmd2", Demand(n2.carrier, fill(1.0, 24)), []), n2)
        connect!(snap, Component("dmd3", Demand(n3.carrier, fill(1.0, 24)), []), n3)

        b12, b23, b31 = -1.5, -0.7, -2.0
        loss12, loss23, loss31 = 0.10, 0.20, 0.30
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; susceptance=b12, lossfactor=loss12)
        makenodeinterco("IC", n2, n3, Inf, Inf, snap; susceptance=b23, lossfactor=loss23)
        makenodeinterco("IC", n3, n1, Inf, Inf, snap; susceptance=b31, lossfactor=loss31)

        Posy2.applydcopf!(snap)
        Nosy.optimize!(snap, cost(snap))
        @test is_solved_and_feasible(sim.model)

        _, _, node_map = Posy2.getic_susceptancematrix(snap)
        f12 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE1", "ZONE2", node_map))
        f23 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE2", "ZONE3", node_map))
        f31 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE3", "ZONE1", node_map))
        @test all(isapprox.(f12 ./ b12 .+ f23 ./ b23 .+ f31 ./ b31, 0.0; atol=1e-6))

        c12 = Nosy.getcomponent(snap, "IC_ZONE1_ZONE2")
        inputs12 = balance(c12, :input, energy, collapse=false, aggregate=false)
        gross12 = JuMP.value.(inputs12["input"] - inputs12["input2"])
        @test all(isapprox.(f12, (1.0 - loss12 / 2) .* gross12; atol=1e-6))
        @test any(abs.(gross12) .> 1e-6)
    end

    # Mixed AC/DC mesh: B-matrix keeps three AC edges only; KVL holds on the triangle while the DC spur is outside cycles.
    let
        snap, sim = makesnapshot()

        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n4 = Node("ZONE4", EnergyCarrier("electricity ZONE4", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])

        src = Component("src", DispatchableSource(n1.carrier), [
            VariableCost(:fuel, "output", energy, 1.0),
            FixedCapacity("output", energy, 100.0),
        ])
        connect!(snap, src, n1)
        d3 = Component("dmd3", Demand(n3.carrier, fill(1.0, 24)), [])
        d4 = Component("dmd4", Demand(n4.carrier, fill(1.0, 24)), [])
        connect!(snap, d3, n3)
        connect!(snap, d4, n4)

        b12, b23, b31 = -1.5, -0.7, -2.0
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=b12)
        makenodeinterco("IC", n2, n3, Inf, Inf, snap; dc=false, susceptance=b23)
        makenodeinterco("IC", n3, n1, Inf, Inf, snap; dc=false, susceptance=b31)
        makenodeinterco("IC", n2, n4, Inf, Inf, snap; dc=true)

        _, _, node_map = Posy2.getic_susceptancematrix(snap)
        @test length(node_map) == 3

        Posy2.applydcopf!(snap)
        Nosy.optimize!(snap, cost(snap))
        @test is_solved_and_feasible(sim.model)

        f12 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE1", "ZONE2", node_map))
        f23 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE2", "ZONE3", node_map))
        f31 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE3", "ZONE1", node_map))
        lhs = f12 ./ b12 .+ f23 ./ b23 .+ f31 ./ b31
        @test all(isapprox.(lhs, 0.0; atol=1e-6))

        ex = extract(snap)
        src_hourly = balance(ex, "src", :output, energy; collapse=false, aggregate=true)
        dmd3_hourly = balance(ex, "dmd3", :input, energy; collapse=false, aggregate=true)
        dmd4_hourly = balance(ex, "dmd4", :input, energy; collapse=false, aggregate=true)
        @test all(isapprox.(src_hourly.data, dmd3_hourly.data .+ dmd4_hourly.data; atol=1e-6))
    end

    # With dcopf false, applydcopf! skips KVL even when AC susceptance is registered.
    let
        snap, sim = makesnapshot(dcopf=false)

        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=-1.0)

        @test Posy2.applydcopf!(snap) === nothing
        @test !Posy2.dcopf(snap)
    end

    # applydcopf! applies once: a second call raises rather than stacking KVL constraints.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=-1.5)
        makenodeinterco("IC", n2, n3, Inf, Inf, snap; dc=false, susceptance=-0.7)
        makenodeinterco("IC", n3, n1, Inf, Inf, snap; dc=false, susceptance=-2.0)

        Posy2.applydcopf!(snap)
        ncons = num_constraints(sim.model; count_variable_in_set_constraints=false)
        @test_throws ArgumentError Posy2.applydcopf!(snap)
        @test num_constraints(sim.model; count_variable_in_set_constraints=false) == ncons
    end

    # Node interconnections are frozen once applydcopf! has run, AC and DC alike.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=-1.5)
        makenodeinterco("IC", n2, n3, Inf, Inf, snap; dc=false, susceptance=-0.7)

        @test_logs (:warn, r"No AC loops were found") Posy2.applydcopf!(snap)
        @test_throws ArgumentError makenodeinterco("IC", n3, n1, Inf, Inf, snap; dc=false, susceptance=-2.0)
        @test_throws ArgumentError makenodeinterco("IC", n3, n1, Inf, Inf, snap; dc=true)
        @test !Nosy.hascomponent(snap, "IC_ZONE3_ZONE1")
    end

    # With dcopf false no marker is set, so interconnections stay editable after applydcopf!.
    let
        snap, sim = makesnapshot(dcopf=false)
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        Posy2.applydcopf!(snap)
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false, susceptance=-1.0)
        @test Nosy.hascomponent(snap, "IC_ZONE1_ZONE2")
    end

    # AC node IC without registered susceptance raises ArgumentError when addkvl! runs.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; dc=false)
        @test_throws ArgumentError Posy2.addkvl!(snap)
    end
end
