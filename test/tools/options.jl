using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Snapshot options" begin
    # discount_rate and co2_price read economy fields from Snapshot.options[:posy].
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(
                :posy => Posy2Options(
                    data_dir=joinpath(@__DIR__, "..", "data"),
                    techdata_file="tech_data_test.xlsx",
                    timeseries_file="time_series_test.xlsx",
                    discount_rate=0.05,
                    co2_price=50.0,
                ),
            ))
        end
        snap = makesnapshot()
        @test discount_rate(snap) == 0.05
        @test co2_price(snap) == 50.0
        @test tech_mode(snap) == :arguments
        @test timeseries_mode(snap) == :arguments
    end

    let
        sim = Sim(Model(HiGHS.Optimizer))
        set_silent(sim.model)
        snap = Snapshot(sim, Dict(:posy => Posy2Options(
            tech_mode=:arguments,
            timeseries_mode=:arguments,
        )))
        @test tech_mode(snap) == :arguments
        @test timeseries_mode(snap) == :arguments
        @test_throws ArgumentError Posy2Options(tech_mode=:automatic)
        @test_throws ArgumentError Posy2Options(timeseries_mode=:automatic)
    end

    # posy_options requires Snapshot.options[:posy].
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict{Symbol,Any}())
        end
        snap = makesnapshot()
        @test_throws ArgumentError posy_options(snap)
    end

    # :posy must be a Posy2Options instance.
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(:posy => "not a Posy2Options"))
        end
        snap = makesnapshot()
        @test_throws ArgumentError posy_options(snap)
    end

end
