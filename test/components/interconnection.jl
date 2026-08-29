using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Interconnection components" begin
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
                discountrate=0.05,
                co2_price=50.0,
            ),
        )
        snap = Snapshot(sim, opts)
        elec1 = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        elec2 = Node("ZONE2", EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
        return snap, elec1, elec2
    end

    # The default creates one optimized capacity shared by both directions.
    let
        s, elec1, elec2 = makesnapshot()
        c = maketransmissionlink("IC", elec1, elec2, s; maxcap=100.0)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "IC_ZONE1_ZONE2") === c
        @test Nosy.hastag(c, :function, "nodeinterconnection")
        capacities = Nosy.getbehaviors(c, Nosy.VariableCapacityBehavior)
        @test length(capacities) == 2
        byport = Dict(capacity.data.pname => capacity for capacity in capacities)
        @test byport["input"].val === byport["input2"].val
        @test byport["input"].data.expr === byport["input2"].data.expr
        zone1_ics = Nosy.getcomponents(s, "ZONE1"; with=[:function => "interconnection", :function => "nodeinterconnection"])
        @test length(zone1_ics) == 1
        @test haskey(zone1_ics, "IC_ZONE1_ZONE2")
    end

    let
        s, elec1, elec2 = makesnapshot()
        c = maketransmissionlink("IC", elec1, elec2, s; cap=100.0, dc=false, susceptance=-2.5)
        @test Posy2.ic_susceptance(s, "ZONE1", "ZONE2") == -2.5
        @test !haskey(c.tags, :susceptance)
        mat, nodelist, node_map = Posy2.getic_susceptancematrix(s)
        @test nodelist == ["ZONE1", "ZONE2"]
        @test mat[1, 2] == -2.5
        @test length(node_map) == 1
    end

    # A second AC on the same unordered pair is rejected (either argument order).
    # A second DC is rejected too; mixed AC+DC on the same pair is allowed.
    let
        s, elec1, elec2 = makesnapshot()
        maketransmissionlink("IC", elec1, elec2, s; cap=100.0, dc=false)
        @test_throws ArgumentError maketransmissionlink("IC2", elec1, elec2, s; cap=100.0, dc=false)
        @test_throws ArgumentError maketransmissionlink("IC2", elec2, elec1, s; cap=100.0, dc=false)
        c_dc = maketransmissionlink("HVDC", elec1, elec2, s; cap=100.0, dc=true)
        @test Nosy.hastag(c_dc, :function, "DC")
        @test_throws ArgumentError maketransmissionlink("HVDC2", elec1, elec2, s; cap=100.0, dc=true)
        @test_throws ArgumentError maketransmissionlink("HVDC2", elec2, elec1, s; cap=100.0, dc=true)
    end

    # Parallel DC alone is rejected; mixed AC+DC on the same pair is allowed either order.
    let
        s, elec1, elec2 = makesnapshot()
        maketransmissionlink("HVDC", elec1, elec2, s; cap=100.0, dc=true)
        @test_throws ArgumentError maketransmissionlink("HVDC2", elec1, elec2, s; cap=100.0, dc=true)
        c_ac = maketransmissionlink("AC", elec1, elec2, s; cap=100.0, dc=false)
        @test Nosy.hastag(c_ac, :function, "AC")
    end

    # Validation failures occur before component or SOS construction.
    let
        s, elec1, elec2 = makesnapshot()
        model = sim(s).model

        function model_size()
            return (
                JuMP.num_variables(model),
                JuMP.num_constraints(model; count_variable_in_set_constraints=true),
                length(Nosy.getcomponents(s)),
            )
        end

        before = model_size()
        for lossfactor in (-0.1, 1.0, Inf, NaN)
            @test_throws ArgumentError maketransmissionlink(
                "Invalid loss", elec1, elec2, s;
                cap=100.0, dir=true, lossfactor=lossfactor,
            )
            @test model_size() == before
        end

        @test_throws ArgumentError maketransmissionlink(
            "Self", elec1, elec1, s; cap=100.0, dir=true,
        )
        @test model_size() == before

        @test_throws ArgumentError maketransmissionlink(
            "Invalid B", elec1, elec2, s;
            cap=100.0, dir=true, susceptance=1.0,
        )
        @test model_size() == before

        maketransmissionlink("IC", elec1, elec2, s; cap=100.0, dc=false)
        before_duplicate = model_size()
        @test_throws ArgumentError maketransmissionlink(
            "Parallel", elec1, elec2, s; cap=100.0, dc=false, dir=true,
        )
        @test model_size() == before_duplicate

        @test_throws ArgumentError maketransmissionlink(
            "IC", elec1, elec2, s; cap=100.0, dc=true, dir=true,
        )
        @test model_size() == before_duplicate
    end

    # Directional SOS construction keeps the second node argument intact.
    let
        s, elec1, elec2 = makesnapshot()
        c = maketransmissionlink("Directional", elec1, elec2, s; cap=100.0, dir=true)
        @test Nosy.getcomponent(s, "Directional_ZONE1_ZONE2") === c
    end

    # Price interconnection succeeds when zone series exist in the fixture.
    let
        s, elec1, _ = makesnapshot()
        c = makepriceinterco("ZONE2", elec1, 100.0, 100.0, s; transactioncost=1.)
        @test !isnothing(c)
        @test Nosy.getcomponent(s, "IC_ZONE2_ZONE1") === c
        @test Nosy.hastag(c, :function, "priceinterconnection")
        @test Nosy.hastag(c, :neighbor, "ZONE2")
        @test get(c.tags, :neighbor, String[]) == ["ZONE2"]
    end

    # Price interconnection fails when spot/transfer columns for the zone are missing.
    let
        s, elec1, _ = makesnapshot()
        @test_throws ArgumentError makepriceinterco("ZONE3", elec1, 100.0, 100.0, s)
    end

    # Both directions zero: no spot price is read, but the import/export costs still
    # hold an hourly series of zeros so that reporting can build them.
    let
        s, elec1, _ = makesnapshot()
        c = makepriceinterco("ZONE2", elec1, 0.0, 0.0, s)
        spot = [
            b.data.val for b in Nosy.getbehaviors(c, Nosy.VariableCostBehavior)
            if Nosy._costtype(b) in (:imports, :exports)
        ]
        @test length(spot) == 2
        @test all(v -> v == zeros(Nosy.nhours(sim(s))), spot)
    end

    # Transfer availabilities are multipliers of the directional capacity, so
    # both interconnection kinds hold them within [0, 1]. Spot prices are free.
    let
        s, elec1, elec2 = makesnapshot()
        @test_throws ArgumentError maketransmissionlink(
            "Above one", elec1, elec2, s; cap=100.0, atob_availability=1.5, btoa_availability=1.0,
        )
        @test_throws ArgumentError maketransmissionlink(
            "Negative", elec1, elec2, s; cap=100.0, atob_availability=1.0, btoa_availability=-0.1,
        )
        @test_throws ArgumentError makepriceinterco(
            "ZONE2", elec1, 100.0, 100.0, s; import_availability=1.5,
        )
        @test !isnothing(makepriceinterco(
            "ZONE2", elec1, 100.0, 100.0, s;
            import_availability=1.0, export_availability=0.0,
        ))
    end

    # Each link type reads its own worksheet: AC from transfer_capacities_AC and
    # DC from transfer_capacities_DC, on the same node pair. The test workbook
    # holds a constant 0.5 in the DC sheet, so the multipliers name their source.
    let
        s, elec1, elec2 = makesnapshot()

        function multipliers(c)
            return Dict(
                b.data.pname => b.val.data
                for b in Nosy.getbehaviors(c, Nosy.CapacityMultiplierBehavior)
            )
        end

        c_ac = maketransmissionlink("AC", elec1, elec2, s; cap=100.0, dc=false)
        c_dc = maketransmissionlink("DC", elec1, elec2, s; cap=100.0, dc=true)

        ac = multipliers(c_ac)
        @test ac["input"] == gettimeseries(s, "ZONE1>ZONE2", "transfer_capacities_AC", digits=2)
        @test ac["input2"] == gettimeseries(s, "ZONE2>ZONE1", "transfer_capacities_AC", digits=2)
        @test multipliers(c_dc) == Dict("input" => fill(0.5, 8760), "input2" => fill(0.5, 8760))
    end

    # Price interconnections keep reading transfer_capacities; the node sheets
    # do not replace it.
    let
        s, elec1, _ = makesnapshot()
        c = makepriceinterco("ZONE2", elec1, 100.0, 100.0, s)
        vals = Dict(
            b.data.pname => b.val.data
            for b in Nosy.getbehaviors(c, Nosy.CapacityMultiplierBehavior)
        )
        @test vals["output"] == gettimeseries(s, "ZONE2>ZONE1", "transfer_capacities")
        @test vals["input"] == gettimeseries(s, "ZONE1>ZONE2", "transfer_capacities")
    end

    # A node pair missing from its own sheet names that sheet, not transfer_capacities.
    let
        s, elec1, _ = makesnapshot()
        elec3 = Node("ZONE3", EnergyCarrier("electricity ZONE3", sim(s)), rule=:curtailed, losses=0.0, tags=[:electricity])
        err = try
            maketransmissionlink("AC", elec1, elec3, s; cap=100.0, dc=false)
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("transfer_capacities_AC", err.msg)
    end

    # Investment and fixed O&M are charged once against the shared capacity.
    let
        s, elec1, elec2 = makesnapshot()
        c = maketransmissionlink(
            "Costed", elec1, elec2, s;
            cap=100.0,
            atob_availability=1.0,
            btoa_availability=0.5,
            overnight_cost=2.0,
            om_fixed_cost=3.0,
            lifetime=20,
            construction_profile=1.0,
        )
        @test fixedcost(c, :investment).constant ≈ 100.0 * eac(2_000.0, 0.05, 20, 1.0)
        @test fixedcost(c, :fom).constant ≈ 100.0 * 3_000.0
        @test all(b.data.pname == "input" for b in Nosy.getbehaviors(c, Nosy.FixedCostBehavior))
    end
end
