using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "PTDF" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer), mesh=TimeMesh(fill(1//1, 24)))
        set_silent(sim.model)
        snap = Snapshot(sim, Dict(
            :posy => Posy2Options(
                data_dir=joinpath(@__DIR__, "..", "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
                tech_mode=:excel,
                timeseries_mode=:excel,
            ),
        ))
        return snap, sim
    end

    # Triangle of equal susceptances: a 1 MW transfer from node 1 to node 2 splits
    # 2/3 on the direct line and 1/3 on the path through node 3.
    let
        mat = [0.0 -1.0 -1.0; -1.0 0.0 -1.0; -1.0 -1.0 0.0]
        ptdf = Posy2.ptdfmatrix(mat, [(1, 2), (2, 3), (1, 3)])
        @test size(ptdf) == (3, 3)
        # a distributed injection has no effect: every row sums to zero
        @test all(isapprox.(sum(ptdf, dims=2), 0.0; atol=1e-9))
        f12, f23, f13 = ptdf * [1.0, -1.0, 0.0]
        @test isapprox(f12, 2 / 3; atol=1e-9)
        @test isapprox(f13, 1 / 3; atol=1e-9)
        @test isapprox(f23, -1 / 3; atol=1e-9)
    end

    # Both formalisms describe the same physics: on a meshed AC network with an
    # AC diagonal they give the same corridor flows, from a different number of
    # constraints (one per cycle against one per line).
    let
        pairs = [("ZONE1", "ZONE2"), ("ZONE2", "ZONE3"), ("ZONE3", "ZONE4"),
                 ("ZONE4", "ZONE1"), ("ZONE1", "ZONE3")]
        function solve(method)
            snap, sim = makesnapshot()
            ncons0 = num_constraints(sim.model; count_variable_in_set_constraints=false)
            n = [Node("ZONE$i", EnergyCarrier("electricity ZONE$i", sim),
                      rule=:curtailed, evalprice=true, tags=[:electricity]) for i in 1:4]
            src = Component("src", DispatchableSource(n[1].carrier), [
                VariableCost(:fuel, "output", energy, 1.0),
                FixedCapacity("output", energy, 100.0),
            ])
            connect!(snap, src, n[1])
            for i in 2:4
                connect!(snap, Component("dmd$i", Demand(n[i].carrier, fill(1.0, 24)), []), n[i])
            end
            makenodeinterco("IC", n[1], n[2], Inf, Inf, snap; susceptance=-1.0)
            makenodeinterco("IC", n[2], n[3], Inf, Inf, snap; susceptance=-2.0)
            makenodeinterco("IC", n[3], n[4], Inf, Inf, snap; susceptance=-1.5)
            makenodeinterco("IC", n[4], n[1], Inf, Inf, snap; susceptance=-2.5)
            makenodeinterco("IC", n[1], n[3], Inf, Inf, snap; susceptance=-3.0)

            Posy2.applydcopf!(snap; method=method)
            added = num_constraints(sim.model; count_variable_in_set_constraints=false) - ncons0
            Nosy.optimize!(snap, cost(snap))
            @test is_solved_and_feasible(sim.model)
            _, _, node_map = Posy2.getic_susceptancematrix(snap)
            flows = [JuMP.value.(Posy2._net_ic_flow(snap, from, to, node_map)) for (from, to) in pairs]
            return flows, added
        end

        cycleflows, cyclecons = solve(:cycles)
        ptdfflows, ptdfcons = solve(:ptdf)
        for (fc, fp) in zip(cycleflows, ptdfflows)
            @test all(isapprox.(fc, fp; atol=1e-6))
        end
        # 2 independent cycles against 5 lines, over 24 time steps
        @test cyclecons == 2 * 24
        @test ptdfcons == 5 * 24
    end

    # ptdfmatrix(::Snapshot) returns the matrix applydcopf! uses, with its labels.
    let
        snap, sim = makesnapshot()
        n = [Node("ZONE$i", EnergyCarrier("electricity ZONE$i", sim),
                  rule=:curtailed, tags=[:electricity]) for i in 1:4]
        makenodeinterco("IC", n[1], n[2], Inf, Inf, snap; susceptance=-1.0)
        makenodeinterco("IC", n[2], n[3], Inf, Inf, snap; susceptance=-2.0)
        makenodeinterco("IC", n[3], n[1], Inf, Inf, snap; susceptance=-3.0)
        # ZONE4 hangs off a DC link, so it is outside the AC network
        makenodeinterco("HVDC", n[2], n[4], Inf, Inf, snap; dc=true)

        p = ptdfmatrix(snap)
        @test p.nodes == ["ZONE1", "ZONE2", "ZONE3", "ZONE4"]
        @test p.lines == [("ZONE1", "ZONE2"), ("ZONE2", "ZONE3"), ("ZONE3", "ZONE1")]
        @test size(p.matrix) == (3, 4)
        @test all(isapprox.(sum(p.matrix, dims=2), 0.0; atol=1e-9))
        # a node served by DC only takes no share of any AC line
        @test all(iszero, p.matrix[:, 4])
        # with ZONE1 as slack, column ZONE2 is a ZONE2 -> ZONE1 transfer: it splits
        # over the direct line (B = -1) and the ZONE1-ZONE3-ZONE2 path (series
        # B = -1.2), and runs against the stored ZONE1 -> ZONE2 row orientation
        slacked = p.matrix .- p.matrix[:, 1]
        @test isapprox(slacked[1, 2], -1 / 2.2; atol=1e-9)
        # topology only: the same matrix before and after the constraints are added
        Posy2.applydcopf!(snap; method=:ptdf)
        @test ptdfmatrix(snap).matrix == p.matrix
    end

    # cyclebasis(::Snapshot) names the cycles applydcopf! constrains.
    let
        snap, sim = makesnapshot()
        n = [Node("ZONE$i", EnergyCarrier("electricity ZONE$i", sim),
                  rule=:curtailed, tags=[:electricity]) for i in 1:4]
        makenodeinterco("IC", n[1], n[2], Inf, Inf, snap; susceptance=-1.0)
        makenodeinterco("IC", n[2], n[3], Inf, Inf, snap; susceptance=-2.0)
        makenodeinterco("IC", n[3], n[1], Inf, Inf, snap; susceptance=-3.0)
        makenodeinterco("HVDC", n[2], n[4], Inf, Inf, snap; dc=true)

        cycles = cyclebasis(snap)
        @test length(cycles) == 1
        # one loop over the three AC nodes; the DC spur is not part of it
        @test Set(only(cycles)) == Set(["ZONE1", "ZONE2", "ZONE3"])
        # as many cycles as the :cycles method writes constraint rows
        ncons0 = num_constraints(sim.model; count_variable_in_set_constraints=false)
        Posy2.applydcopf!(snap; method=:cycles)
        @test num_constraints(sim.model; count_variable_in_set_constraints=false) - ncons0 ==
              length(cycles) * 24
        @test cyclebasis(snap) == cycles
    end

    # A radial network has an empty cycle basis, and a network with no AC line at
    # all still answers with empty labels rather than failing.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; susceptance=-1.0)
        @test isempty(cyclebasis(snap))
        @test size(ptdfmatrix(snap).matrix) == (1, 2)

        empty, _ = makesnapshot()
        @test isempty(cyclebasis(empty))
        @test size(ptdfmatrix(empty).matrix) == (0, 0)
        @test isempty(ptdfmatrix(empty).nodes)
    end

    # Both accessors need the susceptances the constraints are built from.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap)
        @test_throws ArgumentError ptdfmatrix(snap)
        @test_throws ArgumentError cyclebasis(snap)
    end

    # DC links stay out of the PTDF network: only the AC triangle is constrained.
    let
        snap, sim = makesnapshot()
        ncons0 = num_constraints(sim.model; count_variable_in_set_constraints=false)
        n = [Node("ZONE$i", EnergyCarrier("electricity ZONE$i", sim),
                  rule=:curtailed, evalprice=true, tags=[:electricity]) for i in 1:4]
        src = Component("src", DispatchableSource(n[1].carrier), [
            VariableCost(:fuel, "output", energy, 1.0),
            FixedCapacity("output", energy, 100.0),
        ])
        connect!(snap, src, n[1])
        connect!(snap, Component("dmd3", Demand(n[3].carrier, fill(1.0, 24)), []), n[3])
        connect!(snap, Component("dmd4", Demand(n[4].carrier, fill(1.0, 24)), []), n[4])

        b12, b23, b31 = -1.5, -0.7, -2.0
        makenodeinterco("IC", n[1], n[2], Inf, Inf, snap; susceptance=b12)
        makenodeinterco("IC", n[2], n[3], Inf, Inf, snap; susceptance=b23)
        makenodeinterco("IC", n[3], n[1], Inf, Inf, snap; susceptance=b31)
        makenodeinterco("IC", n[2], n[4], Inf, Inf, snap; dc=true)

        Posy2.applydcopf!(snap; method=:ptdf)
        # three AC lines only, the DC spur is left out
        @test num_constraints(sim.model; count_variable_in_set_constraints=false) - ncons0 == 3 * 24
        Nosy.optimize!(snap, cost(snap))
        @test is_solved_and_feasible(sim.model)

        _, _, node_map = Posy2.getic_susceptancematrix(snap)
        f12 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE1", "ZONE2", node_map))
        f23 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE2", "ZONE3", node_map))
        f31 = JuMP.value.(Posy2._net_ic_flow(snap, "ZONE3", "ZONE1", node_map))
        # the PTDF constraints imply KVL around the AC triangle
        @test all(isapprox.(f12 ./ b12 .+ f23 ./ b23 .+ f31 ./ b31, 0.0; atol=1e-6))

        # both accessors read the topology, so an extracted result answers alike
        ex = extract(snap)
        @test ptdfmatrix(ex).matrix == ptdfmatrix(snap).matrix
        @test ptdfmatrix(ex).lines == ptdfmatrix(snap).lines
        @test cyclebasis(ex) == cyclebasis(snap)
    end

    # A radial AC network has nothing to constrain, whichever formalism is asked for.
    let
        snap, sim = makesnapshot()
        ncons0 = num_constraints(sim.model; count_variable_in_set_constraints=false)
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; susceptance=-1.0)

        @test_logs (:warn, r"No AC loops were found") Posy2.applydcopf!(snap; method=:ptdf)
        @test num_constraints(sim.model; count_variable_in_set_constraints=false) == ncons0
    end

    # An unknown formalism is rejected, and leaves the snapshot untouched.
    let
        snap, sim = makesnapshot()
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, tags=[:electricity])
        makenodeinterco("IC", n1, n2, Inf, Inf, snap; susceptance=-1.0)

        @test_throws ArgumentError Posy2.applydcopf!(snap; method=:kirchhoff)
        @test !haskey(snap.options, :kvl_applied)
    end
end
