using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "IC susceptance registry" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        return Snapshot(sim, Dict(
            :posy => Posy2Options(
                data_dir=joinpath(@__DIR__, "..", "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
                tech_mode=:excel,
                timeseries_mode=:excel,
            ),
        ))
    end

    function twonodes(snap)
        sim = Nosy.sim(snap)
        n1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        n2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        return n1, n2
    end

    # maketransmissionlink registers B and ic_susceptance reads it back.
    let
        snap = makesnapshot()
        n1, n2 = twonodes(snap)
        maketransmissionlink("IC", n1, n2, snap; cap=100.0, a_to_b_availability=1.0, b_to_a_availability=1.0, dc=false, susceptance=-3.5)
        @test Posy2.ic_susceptance(snap, "ZONE1", "ZONE2") == -3.5
    end

    # Lookup is undirected: reverse node order finds the same registered value.
    let
        snap = makesnapshot()
        n1, n2 = twonodes(snap)
        maketransmissionlink("IC", n1, n2, snap; cap=100.0, a_to_b_availability=1.0, b_to_a_availability=1.0, dc=false, susceptance=-2.0)
        @test Posy2.ic_susceptance(snap, "ZONE2", "ZONE1") == -2.0
    end

    # Missing pair raises ArgumentError.
    let
        snap = makesnapshot()
        @test_throws ArgumentError Posy2.ic_susceptance(snap, "ZONE1", "ZONE2")
    end

    # Non negative susceptance is rejected.
    let
        snap = makesnapshot()
        n1, n2 = twonodes(snap)
        @test_throws ArgumentError maketransmissionlink("IC", n1, n2, snap; cap=100.0, a_to_b_availability=1.0, b_to_a_availability=1.0, dc=false, susceptance=0.0)
        @test_throws ArgumentError maketransmissionlink("IC", n1, n2, snap; cap=100.0, a_to_b_availability=1.0, b_to_a_availability=1.0, dc=false, susceptance=1.0)
    end

    # Wrong :ic_susceptance type raises ArgumentError.
    let
        snap = makesnapshot()
        snap.options[:ic_susceptance] = Dict{String, Float64}()
        @test_throws ArgumentError Posy2.ic_susceptance(snap, "ZONE1", "ZONE2")
    end
end
