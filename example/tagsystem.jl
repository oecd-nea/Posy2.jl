using POSY2, Nosy
using HiGHS

function makesnapshot(; optimize::Bool=false)
    sim = Sim(Model(HiGHS.Optimizer))
    opts = Dict(
        :posy => POSY2Options(
            data_dir=joinpath(@__DIR__, "..", "test", "data"),
            techdata_file="tech_data_test.xlsx",
            timeseries_file="time_series_test.xlsx",
            discountrate=0.05,
            co2_price=50.0,
        ),
    )
    snap = Snapshot(sim, opts)
    elec = Node("ZONE1", EnergyCarrier("electricity ZONE1", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
    elec2 = Node("ZONE2",EnergyCarrier("electricity ZONE2", sim), rule=:curtailed, evalprice=true, losses=0.0, tags=[:electricity])
    co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

    makedispatchable("CCGT", "CCGT", elec, co2, snap; cap=100.0, construction_profile=1.0, decommissioning_profile=1.0)
    makeintermittentsource("Onwind gen", "Onwind", elec, co2, snap; cap=100.0, weatheryear=2019, construction_profile=1.0, decommissioning_profile=1.0)
    makebatteries(
        "Battery", "Battery", elec, snap;
        capin=100.0, eff=0.9, duration=4.0,
        overnight_cost=1000.0, om_fixed_cost=10.0, decommissioning=0.1, lifetime=20.0,
        construction_profile=1.0, decommissioning_profile=1.0, connection_cost=0.0, om_var_cost=1.0,
    )

    !optimize && return snap, elec, elec2, co2
    Nosy.optimize!(snap, cost(snap))
    return extract(snap), elec, elec2, co2
end

s, elec, elec2, co2 = makesnapshot()
wind = Nosy.getcomponent(s, "Onwind gen ZONE1")
bat = Nosy.getcomponent(s, "Battery ZONE1")
ccgt = Nosy.getcomponent(s, "CCGT ZONE1")

# Do builders attach the kind tags PP relies on (:generation, :dispatchable, :intermittent, :storage)
@assert Nosy.hastag(wind, :generation) && Nosy.hastag(wind, :intermittent)
@assert Nosy.hastag(bat, :storage) && Nosy.hastag(bat, :generation)
@assert Nosy.hastag(ccgt, :generation) && Nosy.hastag(ccgt, :dispatchable)

# Can we find components snapshot-wide with a single kind tag
intermittent = Nosy.getcomponents(s; with=[:intermittent])
storage = Nosy.getcomponents(s; with=[:storage])
dispatchable = Nosy.getcomponents(s; with=[:dispatchable])
@assert haskey(intermittent, "Onwind gen ZONE1")
@assert haskey(storage, "Battery ZONE1")
@assert haskey(dispatchable, "CCGT ZONE1")

# Does without=[:storage] drop overlapping components (battery has both :generation and :storage)
all_generation = Nosy.getcomponents(s; with=[:generation])
generation_without_storage = Nosy.getcomponents(s; with=[:generation], without=[:storage])
@assert length(all_generation) == 3
@assert length(generation_without_storage) == 2

# Can list components on one zone through getcomponents(s, nodename; with=...) (annual PP pattern)
zone1_intermittent = Nosy.getcomponents(s, "ZONE1"; with=[:generation, :intermittent])
@assert haskey(zone1_intermittent, "Onwind gen ZONE1")

zone1_generation = Nosy.getcomponents(s, "ZONE1"; with=[:generation])
@assert length(zone1_generation) == 3

# Does a shared kind tag group two components even when names differ ("Onwind gen" vs "Plant A")
makeintermittentsource("Plant A", "Onwind", elec, co2, s; cap=50.0, weatheryear=2019, construction_profile=1.0, decommissioning_profile=1.0)
intermittent_all = Nosy.getcomponents(s; with=[:intermittent])
@assert length(intermittent_all) == 2
@assert haskey(intermittent_all, "Plant A ZONE1")

# Does makepriceinterco tag kind (:priceinterconnection, :foreign) and external zone Symbol(zone)
price_ic = makepriceinterco("ZONE2", elec, 100.0, 100.0, s)

@assert Nosy.hastag(price_ic, :interconnection)
@assert Nosy.hastag(price_ic, :priceinterconnection)
@assert Nosy.hastag(price_ic, :foreign)
@assert Nosy.hastag(price_ic, :ZONE2)

# Can we find a price IC by external zone tag, and by local node + zone tag
zone2_price_ics = Nosy.getcomponents(s; with=[:priceinterconnection, :ZONE2])
@assert length(zone2_price_ics) == 1
@assert haskey(zone2_price_ics, Nosy.name(price_ic))

zone1_price_ics = Nosy.getcomponents(s, "ZONE1"; with=[:priceinterconnection, :ZONE2])
@assert length(zone1_price_ics) == 1
@assert haskey(zone1_price_ics, Nosy.name(price_ic))