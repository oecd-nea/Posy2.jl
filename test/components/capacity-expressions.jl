using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Expression-backed component capacities" begin
    function expression_snapshot()
        sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
        set_silent(sim.model)
        snapshot = Snapshot(
            sim,
            Dict(:posy => Posy2Options(
                tech_mode=:arguments,
                timeseries_mode=:arguments,
            )),
        )
        elec1 = Node(
            "E1",
            EnergyCarrier("electricity E1", sim);
            rule=:curtailed,
            evalprice=true,
            losses=0.0,
            tags=[:electricity],
        )
        elec2 = Node(
            "E2",
            EnergyCarrier("electricity E2", sim);
            rule=:curtailed,
            evalprice=true,
            losses=0.0,
            tags=[:electricity],
        )
        hydrogen = Node(
            "H2",
            EnergyCarrier("hydrogen", sim);
            rule=:curtailed,
            tags=[:hydrogen],
        )
        carbon = Node(
            "CO2",
            CO2Carrier("carbon", sim);
            rule=:curtailed,
            tags=[:co2],
        )
        return snapshot, elec1, elec2, hydrogen, carbon
    end

    function expression_capacity(component, pname)
        return only(filter(
            behavior -> behavior.data.pname == pname,
            Nosy.getbehaviors(component, Nosy.VariableCapacityBehavior),
        )).data
    end

    let
        s, elec1, elec2, hydrogen, carbon = expression_snapshot()
        shared = @variable(Nosy.uppermodel(sim(s)), lower_bound=0.0)
        affine = 2.0 * shared + 1.0

        dispatchable = makedispatchable(
            "Linked dispatchable", elec1, s; co2_node=carbon, tech_column="unused",
            cap=shared, mincap=1.0, maxcap=100.0,
        )
        nuclear = makenuclear(
            "Linked nuclear", elec1, s; co2_node=carbon, tech_column="unused",
            cap=affine, mincap=1.0, maxcap=100.0,
        )
        intermittent = makeintermittentsource(
            "Linked intermittent", elec1, s; co2_node=carbon, tech_column="unused",
            cap=shared, mincap=1.0, maxcap=100.0, profile=1.0,
        )
        ror = makehydroror(
            "Linked ROR", "unused", elec1, s;
            cap=affine, mincap=1.0, maxcap=100.0, intake=0.0,
        )
        electrolyser = makeelectrolyser(
            "Linked electrolyser", elec1, hydrogen, s; tech_column="unused",
            cap=shared, mincap=1.0, maxcap=100.0,
        )
        battery = makebatterystorage(
            "Linked battery", elec1, s; tech_column="unused",
            power_cap=affine, power_mincap=1.0, power_maxcap=100.0, duration=4.0,
        )
        hydrogen_storage = makehydrogenstorage(
            "Linked hydrogen storage", hydrogen, s; tech_column="unused",
            energy_cap=shared, energy_mincap=1.0, energy_maxcap=100.0,
        )
        response = makedemandresponse("Linked DR", elec1, affine, 1.0, s)
        price_interconnection = makepricelink(
            "external", elec1, s;
            import_cap=shared, export_cap=affine, spot_price=1.0,
        )
        node_interconnection = maketransmissionlink(
            "Linked IC", elec1, elec2, s;
            cap=shared, mincap=1.0, maxcap=100.0,
        )

        variable_cases = (
            (dispatchable, "output"),
            (intermittent, "output"),
            (electrolyser, "input"),
            (hydrogen_storage, "level"),
            (price_interconnection, "output"),
        )
        for (component, pname) in variable_cases
            @test expression_capacity(component, pname).expr === shared
        end

        affine_cases = (
            (nuclear, "output"),
            (ror, "output"),
            (battery, "input"),
            (response, "output"),
            (price_interconnection, "input"),
        )
        for (component, pname) in affine_cases
            @test expression_capacity(component, pname).expr == affine
        end

        node_capacities = Dict(
            behavior.data.pname => behavior
            for behavior in Nosy.getbehaviors(node_interconnection, Nosy.VariableCapacityBehavior)
        )
        @test node_capacities["input"].data.expr === node_capacities["input2"].data.expr
        @test node_capacities["input"].val === node_capacities["input2"].val
        @test coefficient(node_capacities["input"].data.expr, shared) == 1.0
        @test node_capacities["input"].data.expr.constant == 0.0

        @test expression_capacity(dispatchable, "output").lb == 1.0
        @test expression_capacity(dispatchable, "output").ub == 100.0
    end

    # Negative infinity is invalid for every capacity.
    let
        s, elec1, elec2, _, _ = expression_snapshot()
        @test_throws ArgumentError makehydroreservoir(
            "Negative infinite reservoir", "unused", elec1, s; tech_column="unused",
            discharge_cap=1.0, charge_cap=0.0, intake=0.0, energy_cap=-Inf,
        )
        @test_throws ArgumentError maketransmissionlink(
            "Negative infinite IC", elec1, elec2, s; cap=-Inf,
        )
    end

    # Nosy rejects warm starts and integer flags on external affine expressions.
    let
        s, elec1, _, _, carbon = expression_snapshot()
        shared = @variable(Nosy.uppermodel(sim(s)), lower_bound=0.0)
        affine = 2.0 * shared
        @test_throws ArgumentError makenuclear(
            "Warm linked nuclear", elec1, s; co2_node=carbon, tech_column="unused",
            cap=shared, warm_start=10.0,
        )
        @test_throws ArgumentError makenuclear(
            "Integer affine nuclear", elec1, s; co2_node=carbon, tech_column="unused",
            cap=affine, integer_cap=true,
        )
    end

    # Ownership is checked before component construction mutates the target model.
    let
        s, elec1, _, _, carbon = expression_snapshot()
        foreign_model = Model()
        foreign = @variable(foreign_model)
        variables_before = num_variables(sim(s).model)

        @test_throws JuMP.VariableNotOwned makedispatchable(
            "Foreign linked dispatchable", elec1, s; co2_node=carbon, tech_column="unused",
            cap=foreign,
        )
        @test num_variables(sim(s).model) == variables_before

        @test_throws JuMP.VariableNotOwned makedispatchable(
            "Foreign affine dispatchable", elec1, s; co2_node=carbon, tech_column="unused",
            cap=2.0 * foreign + 1.0,
        )
        @test num_variables(sim(s).model) == variables_before
    end
end
