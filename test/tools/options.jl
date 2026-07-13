using POSY2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Snapshot options" begin
    # discountrate and co2_price read economy fields from Snapshot.options[:posy].
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(
                :posy => POSY2Options(
                    data_dir=joinpath(@__DIR__, "..", "data"),
                    techdata_file="tech_data_test.xlsx",
                    timeseries_file="time_series_test.xlsx",
                    discountrate=0.05,
                    co2_price=50.0,
                ),
            ))
        end
        snap = makesnapshot()
        @test discountrate(snap) == 0.05
        @test co2_price(snap) == 50.0
    end

    # posy_options requires Snapshot.options[:posy].
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(:dcopf => true))
        end
        snap = makesnapshot()
        @test_throws ArgumentError posy_options(snap)
    end

    # :posy must be a POSY2Options instance.
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(:posy => "not a POSY2Options"))
        end
        snap = makesnapshot()
        @test_throws ArgumentError posy_options(snap)
    end

    # :dcopf defaults to false when the key is omitted.
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(
                :posy => POSY2Options(
                    data_dir=joinpath(@__DIR__, "..", "data"),
                    techdata_file="tech_data_test.xlsx",
                    timeseries_file="time_series_test.xlsx",
                    discountrate=0.05,
                    co2_price=50.0,
                ),
            ))
        end
        snap = makesnapshot()
        @test !POSY2.dcopf(snap)
    end

    # :dcopf => true is read back as true.
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(
                :posy => POSY2Options(
                    data_dir=joinpath(@__DIR__, "..", "data"),
                    techdata_file="tech_data_test.xlsx",
                    timeseries_file="time_series_test.xlsx",
                    discountrate=0.05,
                    co2_price=50.0,
                ),
                :dcopf => true,
            ))
        end
        snap = makesnapshot()
        @test POSY2.dcopf(snap)
    end

    # :dcopf must be Bool, not another type.
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(
                :posy => POSY2Options(
                    data_dir=joinpath(@__DIR__, "..", "data"),
                    techdata_file="tech_data_test.xlsx",
                    timeseries_file="time_series_test.xlsx",
                    discountrate=0.05,
                    co2_price=50.0,
                ),
                :dcopf => 1,
            ))
        end
        snap = makesnapshot()
        @test_throws ArgumentError POSY2.dcopf(snap)
    end

    # applydcopf! does not add KVL constraints when :dcopf is false.
    let
        function makesnapshot()
            sim = Sim(Model(HiGHS.Optimizer))
            set_silent(sim.model)
            return Snapshot(sim, Dict(
                :posy => POSY2Options(
                    data_dir=joinpath(@__DIR__, "..", "data"),
                    techdata_file="tech_data_test.xlsx",
                    timeseries_file="time_series_test.xlsx",
                    discountrate=0.05,
                    co2_price=50.0,
                ),
            ))
        end
        snap = makesnapshot()
        @test POSY2.applydcopf!(snap) === nothing
    end
end
