using Posy2
using Nosy
using Test
using JuMP
using HiGHS

@testset "Component names and technology labels" begin
    simulation = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh(fill(1 // 1, 24)))
    set_silent(simulation.model)
    snapshot = Snapshot(simulation, Dict(:posy => Posy2Options()))
    electricity = Node(
        "country1", EnergyCarrier("electricity country1", simulation);
        rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity],
    )
    carbon = Node("CO2", CO2Carrier("CO2", simulation); rule=:curtailed, tags=[:co2])
    hydrogen = Node(
        "H2", EnergyCarrier("hydrogen", simulation);
        rule=:curtailed, tags=[:hydrogen],
    )
    reporting_tech = "Grouped technology"

    components = (
        makedemand(
            "Named demand", "unused", electricity, snapshot;
            tech=reporting_tech, profile=1.0,
        ),
        makeflathydrogendemand(
            "Named flat H2 demand", hydrogen, 1.0, snapshot; tech=reporting_tech,
        ),
        makeflexhydrogendemand(
            "Named flexible H2 demand", hydrogen, 1.0, snapshot; tech=reporting_tech,
        ),
        makedemandresponse(
            "Named demand response", electricity, 1.0, 0.0, snapshot;
            tech=reporting_tech,
        ),
        makedispatchable(
            "Named dispatchable", electricity, carbon, snapshot; tech_column="unused",
            tech=reporting_tech, cap=1.0,
        ),
        makenuclear(
            "Named nuclear", electricity, carbon, snapshot; tech_column="unused",
            tech=reporting_tech, cap=1.0,
        ),
        makeintermittentsource(
            "Named intermittent", electricity, carbon, snapshot; tech_column="unused",
            tech=reporting_tech, cap=1.0, profile=1.0,
        ),
        makehydroror(
            "Named run of river", "unused", electricity, snapshot;
            tech=reporting_tech, cap=1.0, intake=0.0,
        ),
        makehydroreservoir(
            "Named reservoir", "unused", electricity, snapshot; tech_column="unused",
            tech=reporting_tech, cap_discharging=1.0, cap_charging=0.0,
            cap_reservoir=1.0, intake=0.0,
        ),
        makebatterystorage(
            "Named battery", electricity, snapshot; tech_column="unused",
            tech=reporting_tech, cap=1.0, duration=1.0,
        ),
        makehydrogenstorage(
            "Named H2 storage", hydrogen, snapshot; tech_column="unused",
            tech=reporting_tech, cap=1.0,
        ),
        makeelectrolyser(
            "Named electrolyser", electricity, hydrogen, snapshot; tech_column="unused",
            tech=reporting_tech, cap=1.0,
        ),
        makeflathydrogenpurchase(
            "Named H2 purchase", hydrogen, 1.0, snapshot; tech=reporting_tech,
        ),
        makeEV(
            "Named EV", electricity, snapshot;
            tech=reporting_tech,
            fixed_profile=false, smart_charging=true,
            number_ev=100.0, initial_connected_share=1.0,
            departures=0.0, arrivals=0.0,
            departure_soc=0.8, arrival_soc=0.8,
            max_charging_power_per_ev=0.01,
            battery_capacity_per_ev=0.06,
        ),
    )

    @test all(c -> Nosy.hastag(c, :tech, reporting_tech), components)
    @test length(unique(c.name for c in components)) == length(components)
    @test length(getcomponents(snapshot; with=[:tech => reporting_tech])) == length(components)
    @test Nosy.getcomponent(snapshot, "Named dispatchable country1") === components[5]

    default_tech = makedemand(
        "Default technology", "unused", electricity, snapshot; profile=1.0,
    )
    @test Nosy.hastag(default_tech, :tech, "Default technology")
end
