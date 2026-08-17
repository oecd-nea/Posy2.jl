# Tests run with pwd() set to test/ so readtechdata/readtimeseries resolve test/data/.
@testset "Read data" begin

    @testset "readtechdata and readtimeseries" begin
        cd(dirname(@__DIR__)) do
            # Posy2 reads joinpath(pwd(), "data", filename); expect workbooks under test/data/.
            xl_tech = readtechdata("tech_data_test.xlsx")
            xl_ts = readtimeseries("time_series_test.xlsx")
            @test "dispatchable" in XLSX.sheetnames(xl_tech)
            @test "demand" in XLSX.sheetnames(xl_ts)
            @test gettechparam(xl_tech, "CCGT", "overnight_cost", "dispatchable", 6) == 1000.0
            demand = gettimeseries(xl_ts, "ZONE1", "demand", 6)
            @test length(demand) == 8760 && demand[1] == 100.0
        end

        # Without data/ under pwd(), readtechdata should fail (not find the file).
        mktempdir() do tmp
            cd(tmp) do
                @test_throws Exception readtechdata("tech_data_test.xlsx")
            end
        end
    end

    @testset "Technology workbook parameters" begin
        cd(dirname(@__DIR__)) do
            xl = readtechdata("tech_data_test.xlsx")

            # Known values from test/data/tech_data_test.xlsx.
            @test gettechparam(xl, "CCGT", "overnight_cost", "dispatchable", 6) == 1000.0
            @test gettechparam(xl, "CCGT", "lifetime", "dispatchable", 6) == 30
            @test gettechparam(xl, "Onwind", "overnight_cost", "intermittent", 6) == 1200.0
            
            # Missing sheet: expect ArgumentError (message lists available sheets)
            @test_throws ArgumentError gettechparam(xl, "CCGT", "overnight_cost", "missing_sheet", 6)
            # Unknown technology column on an otherwise valid sheet
            @test_throws ArgumentError gettechparam(xl, "NoSuchTech", "overnight_cost", "dispatchable", 6)
            # Unknown parameter row (no tech column entry matching the param name)
            @test_throws ArgumentError gettechparam(xl, "CCGT", "no_such_param", "dispatchable", 6)
        end
    end

    @testset "Documented shipped technology keys" begin
        xl = readtechdata("tech_data.xlsx"; data_dir=joinpath(pkgdir(Posy2), "data"))
        for param in (
            "overnight_cost", "om_fixed_cost", "om_var_cost", "decommissioning",
            "lifetime", "construction_profile", "decommissioning_profile",
        )
            @test !ismissing(gettechparam(xl, "Hydro ror", param, "intermittent", 6))
        end
        for param in (
            "roundtrip_eff", "overnight_cost", "om_fixed_cost", "decommissioning",
            "lifetime", "construction_profile", "decommissioning_profile",
        )
            @test !ismissing(gettechparam(xl, "Hydrogen storage", param, "storage", 6))
        end
    end

    @testset "Time series workbook columns" begin
        cd(dirname(@__DIR__)) do
            xl = readtimeseries("time_series_test.xlsx")

            # demand sheet, column ZONE1: constant 100.0 MW per hour in the fixture
            demand = gettimeseries(xl, "ZONE1", "demand", 6)
            @test length(demand) == 8760
            @test demand[1] == 100.0

            # profiles_2019 sheet, column Onwind_ZONE1: constant 0.35 in the fixture
            wind = gettimeseries(xl, "Onwind_ZONE1", "profiles_2019", 6)
            @test length(wind) == 8760
            @test wind[1] == 0.35

            # Missing sheet: expect ArgumentError
            @test_throws ArgumentError gettimeseries(xl, "ZONE1", "missing_sheet", 6)
            # Valid sheet but column name not present
            @test_throws ArgumentError gettimeseries(xl, "NoSuchColumn", "demand", 6)
        end
    end

end
