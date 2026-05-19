"""
Functions for V2G component.
"""

"""
    makeEV_flexible(name::String, tech::String, yearly::Number, zone::String, elec::Node, v2g::Bool, s::Snapshot; compensation::Number=0.)
Return a flexible EV fleet, allowing dynamic charging / discharging to the grid.
Parameters:
  * yearly: yearly consumption in MWh
  * consumptionprofile: 8760h driving shape read from `ev_driving_profile` / `zone` (normalized; scaled by `yearly`)
  * chargingstationprofile: 8760h fraction of fleet connected to a charger
  * v2g: if true, the EV fleet can perform V2G operations. Otherwise, it is charging only.
  * compensation: in USD/MWh, compensation to V2G owners for use of the battery.
"""
function makeEV_flexible(name::String, tech::String, yearly::Number, zone::String, elec::Node, v2g::Bool, s::Snapshot; compensation::Number=0.)

    # efficiency on storage output port (V2G discharge); grid charging uses input at efficiency 1
    eff = gettechparam(s, tech, "charging_eff", "storage")
    # hourly self-discharge
    sd = gettechparam(s, tech, "self_discharge", "storage")

    # min level of the battery of the average fleet at 7am: 80%
    min_level_ratio_morning = gettechparam(s, tech, "min_level_morning", "storage")

    # assumptions about EV
    max_charging_per_ev = gettechparam(s, tech, "max_charging_power", "storage")
    max_dispatch_per_ev = gettechparam(s, tech, "max_dispatch_power", "storage")
    battery_cap_per_ev = gettechparam(s, tech, "battery_capacity", "storage")
    yearly_per_ev = gettechparam(s, tech, "yearly_consumption", "storage")
    number_ev = yearly / yearly_per_ev
    max_charging_power = number_ev * max_charging_per_ev
    max_dispatch_power = number_ev * max_dispatch_per_ev
    max_battery_capacity = number_ev * battery_cap_per_ev

    # profile for being connected to charging station
    chargingstationprofile = gettimeseries(s, zone, "EV_charging_availability")

    # generate consumption by applying normalized profile to yearly consumption
    driving = gettimeseries(s, zone, "EV_driving_profile")
    driving = driving ./ sum(driving)
    consumption = driving * yearly

    m = LazyStorage(elec.carrier, eff=Dict("input"=>1., "output"=>eff, "driving"=>1.), self_discharge=sd, simplified=true)
    vb = []

    # input: flexible charging, with availability multiplier
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, FixedCapacity("input", energy, max_charging_power))
    push!(vb, CapacityMultiplier("input", chargingstationprofile))

    # output - V2G: flexible discharging, with availability multiplier related to V2G ratio and connection to charging station
    if v2g
        push!(vb, FreeJointFlow("output", elec.carrier, :output))
        push!(vb, FixedCapacity("output", energy, max_dispatch_power))
        push!(vb, CapacityMultiplier("output", chargingstationprofile))
        if !isnothing(compensation)
            push!(vb, VariableCost(:vom, "output", energy, compensation))
        end
    end
    
    # level - also subject to availability multiplier
    push!(vb, FixedCapacity("level", energy, max_battery_capacity))
    push!(vb, CapacityMultiplier("level", chargingstationprofile))

    # output - driving: fixed profile, no capacity
    # the consumption is performed as soon as the car leaves the charging station
    push!(vb, FixedJointFlow("driving", EnergyCarrier(name, sim(elec)), :output, consumption, mustconnect=false)) # this port does not need connection

    c = Component(name * " " * elec.name, m, vb)

    # level limits
    # ensure the EVs are charged enough at 7am
    @constraint(
        sim(elec).model,
        Nosy.balance(c, :level, energy, collapse=false, aggregate=true).data[8:24:end] .>= min_level_ratio_morning * max_battery_capacity * chargingstationprofile[8:24:end]
    )

    for t in (:electricity, :ev) # ev tag: must have "driving" output. No :storage tag because charging balance is handled differently for EV to avoid double-counting
        tag!(c, t)
    end
    v2g && tag!(c, :generation)
    connect!(s, c, elec)

    return c
end