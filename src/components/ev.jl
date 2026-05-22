"""
Data structures and functions for V2G component.
"""

"""
    ev_connected_profile(shiftdays=0)
Return a normalized EV year consumption profile.
Use shiftdays to shift the series to adjust the starting day: 0 is Monday, 1 is Tuesday etc.
"""
function ev_consumption_profile(shiftdays=0)
    return _weekly_to_yearly_with_shift(_ev_consumption_profile_weekly(), shiftdays, true)
end

"""
    ev_availability_profile(shiftdays=0)
Return a profile for EVs being connected to charging station and available for charging (+possibly discharge if V2G is enabled).
Use shiftdays to shift the series to adjust the starting day: 0 is Monday, 1 is Tuesday etc.
"""
function ev_availability_profile(shiftdays=0)
    return _weekly_to_yearly_with_shift(_ev_availability_profile_weekly(), shiftdays, false)
end

function _weekly_to_yearly_with_shift(weekly, shiftdays, normalize)
    @assert length(weekly) ==168
    v = circshift(weekly, shiftdays)
    s = v[mod1.(1:8760, length(v))]
    if normalize
        return s / sum(s)
    else
        return s
    end
end

"""
    ev_consumption_profile_weekly()
Return a weekly EV consumption profile, starting on monday.
"""
function _ev_consumption_profile_weekly()

    weekday = [
        0.10, 0.05, 0.05, 0.05, 0.10, 0.20,  # 0–5h   night / very early
        0.50, 0.90, 1.00, 0.60, 0.40, 0.35,  # 6–11h  morning peak
        0.40, 0.45, 0.45, 0.50, 0.70, 0.95,  # 12–17h midday / build-up
        0.90, 0.80, 0.60, 0.40, 0.25, 0.15,  # 18–23h evening peak / wind-down
    ]
    
    weekend = [
        0.10, 0.05, 0.05, 0.05, 0.05, 0.10,  # 0–5h
        0.20, 0.30, 0.40, 0.50, 0.55, 0.55,  # 6–11h
        0.55, 0.50, 0.50, 0.45, 0.40, 0.35,  # 12–17h
        0.30, 0.25, 0.20, 0.20, 0.15, 0.10,  # 18–23h
    ]
    
    # day 0=Mon … 4=Fri, 5=Sat, 6=Sun
    profile = Float64[]
    for day in 0:6
        shape = day < 5 ? weekday : weekend
        append!(profile, shape)
    end
    
    return profile
end

"""
    ev_availability_profile()
Return a weekly EV profile for being connected to a station, starting on monday.
"""
function _ev_availability_profile_weekly()
    weekday = [
        0.88, 0.90, 0.91, 0.91, 0.90, 0.85,  # 0–5h   overnight
        0.72, 0.61, 0.60, 0.63, 0.65, 0.66,  # 6–11h  morning commute dip
        0.65, 0.64, 0.63, 0.62, 0.61, 0.63,  # 12–17h midday plateau
        0.68, 0.74, 0.80, 0.85, 0.87, 0.88,  # 18–23h evening recovery
    ]
    weekend = [
        0.88, 0.90, 0.91, 0.91, 0.90, 0.88,  # 0–5h
        0.84, 0.80, 0.76, 0.73, 0.71, 0.70,  # 6–11h  shallow leisure dip
        0.70, 0.70, 0.71, 0.72, 0.73, 0.75,  # 12–17h
        0.78, 0.82, 0.85, 0.87, 0.88, 0.88,  # 18–23h
    ]
    return reduce(vcat, day < 5 ? weekday : weekend for day in 0:6)
end

struct EV
    max_charging_power::Float64 # MW
    max_dispatch_power::Float64 # MW
    battery_capacity::Float64 # MWh
    yearly::Float64 # MWh (yearly consumption for 1 EV)
end

"""
    makeEV_flexible(name::String, yearly::Number, elec::Node, v2g::Bool, s::Snapshot, compensation::Number=0.)
Return a flexible EV fleet, allowing dynamic charging / discharging to the grid.
Parameters:
  * yearly: yearly consumption in TWh
  * consumptionprofile: 8760h time series profile for consumption (driving)
  * chargingstationprofile: 8760h time series profile indicating which fraction of the fleet is connected to a charging station (available for charging and discharging)
  * v2g: if true, the EV fleet can perform V2G operations. Otherwise, it is charging only.
  * compensation: in USD/MWh, compensation to V2G owners for use of the battery.
"""
function makeEV_flexible(name::String, yearly::Number, elec::Node, v2g::Bool, s::Snapshot; compensation::Number=0.)
    
    # efficiency of battery
    eff = 0.90 # charging to level efficiency
    sd = 3E-5 # hourly self-discharge

    # min level of the battery of the average fleet at 7am: 80%
    min_level_ratio_morning = 0.80

    # assumptions about EV
    ev = EV(0.01, 0.01, 0.1, 2)
    number_ev = yearly / ev.yearly
    max_charging_power = number_ev * ev.max_charging_power
    max_dispatch_power = number_ev * ev.max_dispatch_power
    max_battery_capacity = number_ev * ev.battery_capacity

    # profile for being connected to charging station
    chargingstationprofile = ev_availability_profile()
    
    # generate consumption by applying normalized profile to yearly consumption
    consumption = ev_consumption_profile() * yearly

    m = LazyStorage(elec.carrier, eff=Dict("input"=>1., "output"=>1/eff, "driving"=>1.), self_discharge=sd, simplified=true)
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