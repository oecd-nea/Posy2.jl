using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "IC admittance" begin
    function makesnapshot()
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        return Snapshot(sim, Dict(
            :posy => POSY2Options(
                data_dir=joinpath(@__DIR__, "..", "data"),
                techdata_file="tech_data_test.xlsx",
                timeseries_file="time_series_test.xlsx",
            ),
        ))
    end

    # register_ic_admittance! stores B and ic_admittance reads it back.
    let
        snap = makesnapshot()
        POSY2.register_ic_admittance!(snap, "ZONE1", "ZONE2", 3.5)
        @test POSY2.ic_admittance(snap, "ZONE1", "ZONE2") == 3.5
    end

    # Lookup is undirected: reverse node order finds the same registered value.
    let
        snap = makesnapshot()
        POSY2.register_ic_admittance!(snap, "ZONE1", "ZONE2", 2.0)
        @test POSY2.ic_admittance(snap, "ZONE2", "ZONE1") == 2.0
    end

    # Missing pair raises ArgumentError.
    let
        snap = makesnapshot()
        @test_throws ArgumentError POSY2.ic_admittance(snap, "ZONE1", "ZONE2")
    end

    # Non positive admittance is rejected.
    let
        snap = makesnapshot()
        @test_throws ArgumentError POSY2.register_ic_admittance!(snap, "ZONE1", "ZONE2", 0.0)
        @test_throws ArgumentError POSY2.register_ic_admittance!(snap, "ZONE1", "ZONE2", -1.0)
    end

    # Wrong :ic_admittance type raises ArgumentError.
    let
        snap = makesnapshot()
        snap.options[:ic_admittance] = Dict{String, Float64}()
        @test_throws ArgumentError POSY2.ic_admittance(snap, "ZONE1", "ZONE2")
    end
end
