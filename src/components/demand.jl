"""
Generate demand-side components.
"""

using ArgCheck: @argcheck

"""
    makedemand(cname::String, zone::String, n::Node, s::Snapshot;
        coeff=1.0, shift::Int=0, yearlyconstant::Number=0., gridlosses=0.,
    )

Build, connect and return a component based on the Demand template.

Arguments:
  * cname: component name prefix.
  * zone: time series name in the time series workbook (`demand` sheet).
  * n: demand node to connect the component to.
  * s: snapshot to register the component in.
  * coeff: multiplicative factor applied to the profile part of demand.
  * shift: circular shift of demand profile (e.g. align first day to Monday).
  * yearlyconstant: flat yearly demand term distributed over 8760 hours (`yearlyconstant >= 0`).
  * gridlosses: optional proportional grid loss joint flow on demand input (`0 <= gridlosses < 1`).
"""
function makedemand(cname::String, zone::String, n::Node, s::Snapshot; coeff=1.0, shift::Int=0, yearlyconstant::Number=0., gridlosses=0.)
    @argcheck coeff isa Number "coeff must be Number."
    @argcheck coeff >= 0 "coeff must be >= 0."
    @argcheck yearlyconstant isa Number "yearlyconstant must be Number."
    @argcheck yearlyconstant >= 0 "yearlyconstant must be >= 0."
    @argcheck gridlosses isa Number "gridlosses must be Number."
    @argcheck 0 <= gridlosses < 1 "gridlosses must be in [0, 1)."
    _gridlosses = Float64(gridlosses)
    if iszero(coeff)
        var = 0.
    else
        var = coeff * gettimeseries(s, zone, "demand") 
        circshift!(var, shift)
    end

    m = Demand(n.carrier, (var .+ yearlyconstant / 8760))
    vb = []
    !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", n.carrier, :input, "input", x->x[1] * _gridlosses))
    c = Component(cname * " " * n.name, m, vb)
    for t in (:electricity, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)   
    return c
end

"""
    makeflathydrogendemand(cname::String, n::Node, val::Number, s::Snapshot)

Build, connect and return a flat hydrogen demand component.

Arguments:
  * cname: component name prefix.
  * n: hydrogen demand node to connect the component to.
  * val: total yearly hydrogen demand. Must satisfy `val >= 0`.
  * s: snapshot to register the component in.
"""
function makeflathydrogendemand(cname::String, n::Node, val::Number, s::Snapshot)
    @argcheck val >= 0 "val must be >= 0."
    m = Demand(n.carrier, val / 8760)
    vb = []
    c = Component(cname * " " * n.name, m, vb)
    for t in (:hydrogen, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)
    return c
end

"""
    makeflexhydrogendemand(cname::String, n::Node, val::Number, s::Snapshot)

Build, connect and return a flexible hydrogen demand component.

Arguments:
  * cname: component name prefix.
  * n: hydrogen demand node to connect the component to.
  * val: total yearly hydrogen demand enforced through `YearlySum("input", val, :equal)`. Must satisfy `val >= 0`.
  * s: snapshot to register the component in.
"""
function makeflexhydrogendemand(cname::String, n::Node, val::Number, s::Snapshot)
    @argcheck val >= 0 "val must be >= 0."
    m = BasicSink(n.carrier)
    vb = []
    push!(vb, YearlySum("input", val, :equal))
    c = Component(cname * " " * n.name, m, vb)
    for t in (:hydrogen, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)
    return c
end

# Functions for V2G component.
"""
    makeEV(cname::String, yearly::Number, elec::Node, s::Snapshot;
        fixed_profile::Bool=true, smart_charging::Bool=false, vehicle_to_grid::Bool=false,
        offhours1=nothing, offhours2=nothing, minratio=nothing, days_threshold::Integer=104,
        zone::Union{Nothing,String}=nothing, tech::String="EV",
        compensation::Number=0., gridlosses=0.,
        charging_eff::Union{Nothing,Number}=nothing, self_discharge::Union{Nothing,Number}=nothing, min_level_morning::Union{Nothing,Number}=nothing,
        max_charging_power_per_ev::Union{Nothing,Number}=nothing, max_dispatch_power_per_ev::Union{Nothing,Number}=nothing,
        battery_capacity_per_ev::Union{Nothing,Number}=nothing, yearly_consumption_per_ev::Union{Nothing,Number}=nothing,
    )

Build, connect and return an EV component.

Arguments:
  * cname: Component name prefix.
  * yearly: Yearly EV electricity consumption (MWh/year). Must be non-negative.
  * elec: Electricity node to connect EV charging/discharging flows.
  * s: Target snapshot where the EV component and behaviors are registered.

  * fixed_profile: Enable fixed-profile EV demand mode (deterministic hourly charging profile).
  * smart_charging: Enable flexible charging mode (charging only, no discharge to grid).
  * vehicle_to_grid: Enable flexible charging + grid discharge (V2G) mode.
    Exactly one of `fixed_profile`, `smart_charging`, `vehicle_to_grid` must be `true`.

  * offhours1: Winter off-hour indices (0-23). Required when `fixed_profile=true`; ignored otherwise.
  * offhours2: Summer off-hour indices (0-23). Required when `fixed_profile=true`; ignored otherwise.
  * minratio: Relative charging level during off-hours (`0 <= minratio <= 1`). Required when `fixed_profile=true`; ignored otherwise.
  * days_threshold: Number of first winter days before summer segment in fixed-profile assembly (`0 <= days_threshold <= 183`, used only when `fixed_profile=true`).

  * zone: Zone key used to read EV time series (`EV_charging_availability`, `EV_driving_profile`). Required in flexible/V2G modes.
  * tech: Technology row name in the `storage` tech data sheet for EV parameters (used in flexible/V2G modes).
  * compensation: V2G compensation in USD/MWh applied to EV discharge output in V2G mode (ignored in non-V2G modes).
  * gridlosses: Optional proportional grid-loss linked flow on EV input in fixed_profile mode (`0 <= gridlosses < 1`).
  * charging_eff: Optional override for `storage.charging_eff` in flexible/V2G modes (`0 < charging_eff <= 1`). If `nothing`, value is read from Excel.
  * self_discharge: Optional override for `storage.self_discharge` in flexible/V2G modes (`0 <= self_discharge < 1`). If `nothing`, value is read from Excel.
  * min_level_morning: Optional override for `storage.min_level_morning` in flexible/V2G modes (`0 <= min_level_morning <= 1`). If `nothing`, value is read from Excel.
  * max_charging_power_per_ev: Optional override for `storage.max_charging_power` in flexible/V2G modes (`> 0`). If `nothing`, value is read from Excel.
  * max_dispatch_power_per_ev: Optional override for `storage.max_dispatch_power` in flexible/V2G modes (`>= 0`). If `nothing`, value is read from Excel.
  * battery_capacity_per_ev: Optional override for `storage.battery_capacity` in flexible/V2G modes (`> 0`). If `nothing`, value is read from Excel.
  * yearly_consumption_per_ev: Optional override for `storage.yearly_consumption` in flexible/V2G modes (`> 0`). If `nothing`, value is read from Excel.
"""
function makeEV(cname::String, yearly::Number, elec::Node, s::Snapshot; fixed_profile::Bool=true, smart_charging::Bool=false, vehicle_to_grid::Bool=false,

    # fixed-profile inputs
    offhours1=nothing, offhours2=nothing, minratio=nothing, days_threshold::Integer=104,

    # flexible / V2G inputs
    zone::Union{Nothing,String}=nothing, tech::String="EV", compensation::Number=0., gridlosses=0.,
    charging_eff::Union{Nothing,Number}=nothing, self_discharge::Union{Nothing,Number}=nothing, min_level_morning::Union{Nothing,Number}=nothing,
    max_charging_power_per_ev::Union{Nothing,Number}=nothing, max_dispatch_power_per_ev::Union{Nothing,Number}=nothing,
    battery_capacity_per_ev::Union{Nothing,Number}=nothing, yearly_consumption_per_ev::Union{Nothing,Number}=nothing,)
    @argcheck yearly isa Number "yearly must be Number."
    @argcheck yearly >= 0 "yearly must be >= 0."
    _yearly = Float64(yearly)
    @argcheck gridlosses isa Number "gridlosses must be Number."
    @argcheck 0 <= gridlosses < 1 "gridlosses must be in [0, 1)."
    _gridlosses = Float64(gridlosses)
    @argcheck compensation isa Number "compensation must be Number or left as default."
    _compensation = Float64(compensation)

    mode_count = Int(fixed_profile) + Int(smart_charging) + Int(vehicle_to_grid)
    @argcheck mode_count == 1 "Exactly one of fixed_profile, smart_charging, vehicle_to_grid must be true."

    if fixed_profile
        @argcheck !isnothing(offhours1) "offhours1 is required when fixed_profile=true."
        @argcheck !isnothing(offhours2) "offhours2 is required when fixed_profile=true."
        @argcheck !isnothing(minratio) "minratio is required when fixed_profile=true."
        @argcheck offhours1 isa AbstractVector{<:Int} "offhours1 must be a vector of integers."
        @argcheck offhours2 isa AbstractVector{<:Int} "offhours2 must be a vector of integers."
        @argcheck minratio isa Number "minratio must be Number."
        @argcheck 0 <= minratio <= 1 "minratio must be in [0, 1]."
        @argcheck 0 <= days_threshold <= 183 "days_threshold must be in [0, 183]."
        @argcheck all(0 <= h <= 23 for h in offhours1) "offhours1 must be integers between 0 and 23."
        @argcheck all(0 <= h <= 23 for h in offhours2) "offhours2 must be integers between 0 and 23."

        _minratio = Float64(minratio)
        maxlevel =
            _yearly / (
                (183 * ((24 - length(offhours1)) + length(offhours1) * _minratio)) +
                182 * ((24 - length(offhours2)) + length(offhours2) * _minratio)
            )

        series = vcat(
            repeat([h in offhours1 ? _minratio : 1.0 for h in 0:23], days_threshold), # winter
            repeat([h in offhours2 ? _minratio : 1.0 for h in 0:23], 182), # summer
            repeat([h in offhours1 ? _minratio : 1.0 for h in 0:23], 183 - days_threshold), # winter
        ) * maxlevel

        m = Demand(elec.carrier, series)
        vb = []
        !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x -> x[1] * _gridlosses))
        c = Component(cname * " " * elec.name, m, vb)
        for t in (:electricity, :demand)
            tag!(c, t)
        end
        connect!(s, c, elec)
        return c
    else
        @argcheck !isnothing(zone) "zone is required when smart_charging or vehicle_to_grid is enabled."
        @argcheck zone isa String "zone must be a String."

        # efficiency on storage output port (V2G discharge); grid charging uses input at efficiency 1
        eff = isnothing(charging_eff) ? gettechparam(s, tech, "charging_eff", "storage") : charging_eff
        @argcheck eff isa Number "charging_eff must be Number."
        @argcheck 0 < eff <= 1 "charging_eff must be in (0, 1]."
        # hourly self-discharge
        sd = isnothing(self_discharge) ? gettechparam(s, tech, "self_discharge", "storage") : self_discharge
        @argcheck sd isa Number "self_discharge must be Number."
        @argcheck 0 <= sd < 1 "self_discharge must be in [0, 1)."

        # min level of the battery of the average fleet at 7am: 80%
        min_level_ratio_morning = isnothing(min_level_morning) ? gettechparam(s, tech, "min_level_morning", "storage") : min_level_morning
        @argcheck min_level_ratio_morning isa Number "min_level_morning must be Number."
        @argcheck 0 <= min_level_ratio_morning <= 1 "min_level_morning must be in [0, 1]."

        # assumptions about EV
        max_charging_per_ev = isnothing(max_charging_power_per_ev) ? gettechparam(s, tech, "max_charging_power", "storage") : max_charging_power_per_ev
        max_dispatch_per_ev = isnothing(max_dispatch_power_per_ev) ? gettechparam(s, tech, "max_dispatch_power", "storage") : max_dispatch_power_per_ev
        battery_cap_per_ev = isnothing(battery_capacity_per_ev) ? gettechparam(s, tech, "battery_capacity", "storage") : battery_capacity_per_ev
        yearly_per_ev = isnothing(yearly_consumption_per_ev) ? gettechparam(s, tech, "yearly_consumption", "storage") : yearly_consumption_per_ev
        @argcheck max_charging_per_ev isa Number "max_charging_power must be Number."
        @argcheck max_charging_per_ev > 0 "max_charging_power must be > 0."
        @argcheck max_dispatch_per_ev isa Number "max_dispatch_power must be Number."
        @argcheck max_dispatch_per_ev >= 0 "max_dispatch_power must be >= 0."
        @argcheck battery_cap_per_ev isa Number "battery_capacity must be Number."
        @argcheck battery_cap_per_ev > 0 "battery_capacity must be > 0."
        @argcheck yearly_per_ev isa Number "yearly_consumption must be Number."
        @argcheck yearly_per_ev > 0 "yearly_consumption must be > 0."
        number_ev = _yearly / yearly_per_ev
        max_charging_power = number_ev * max_charging_per_ev
        max_dispatch_power = number_ev * max_dispatch_per_ev
        max_battery_capacity = number_ev * battery_cap_per_ev

        # profile for being connected to charging station
        chargingstationprofile = gettimeseries(s, zone, "EV_charging_availability")

        # generate consumption by applying normalized profile to yearly consumption
        driving = gettimeseries(s, zone, "EV_driving_profile")
        @argcheck sum(driving) > 0 "EV_driving_profile must have a strictly positive sum."
        driving = driving ./ sum(driving)
        consumption = driving * _yearly

        m = LazyStorage(elec.carrier, eff=Dict("input" => 1., "output" => eff, "driving" => 1.), self_discharge=sd, simplified=true)
        vb = []

        # input: flexible charging, with availability multiplier
        push!(vb, FreeJointFlow("input", elec.carrier, :input))
        push!(vb, FixedCapacity("input", energy, max_charging_power))
        push!(vb, CapacityMultiplier("input", chargingstationprofile))

        # output - V2G: flexible discharging, with availability multiplier related to V2G ratio and connection to charging station
        if vehicle_to_grid
            push!(vb, FreeJointFlow("output", elec.carrier, :output))
            push!(vb, FixedCapacity("output", energy, max_dispatch_power))
            push!(vb, CapacityMultiplier("output", chargingstationprofile))
            if !isnothing(compensation)
                push!(vb, VariableCost(:vom, "output", energy, _compensation))
            end
        end

        # level - also subject to availability multiplier
        push!(vb, FixedCapacity("level", energy, max_battery_capacity))
        push!(vb, CapacityMultiplier("level", chargingstationprofile))

        # output - driving: fixed profile, no capacity
        # the consumption is performed as soon as the car leaves the charging station
        push!(vb, FixedJointFlow("driving", EnergyCarrier(cname, sim(elec)), :output, consumption, mustconnect=false)) # this port does not need connection

        c = Component(cname * " " * elec.name, m, vb)

        # level limits
        # ensure the EVs are charged enough at 7am
        @constraint(
            sim(elec).model,
            Nosy.balance(c, :level, energy, collapse=false, aggregate=true).data[8:24:end] .>= min_level_ratio_morning * max_battery_capacity * chargingstationprofile[8:24:end]
        )

        for t in (:electricity, :ev) # ev tag: must have "driving" output. No :storage tag because charging balance is handled differently for EV to avoid double-counting
            tag!(c, t)
        end
        vehicle_to_grid && tag!(c, :generation)
        connect!(s, c, elec)

        return c
    end
end

"""
    makedemandresponse(cname::String, elec::Node, capa::Union{Nothing,Number}, cost::Number, s::Snapshot; type::Symbol=:volDR)

Build, connect and return a demand response component.

Arguments:
  * cname: component name prefix.
  * elec: electricity node to connect the component to.
  * capa: optional fixed response capacity (`nothing` means unconstrained).
  * cost: demand response activation cost coefficient.
  * s: snapshot to register the component in.
  * type: variable cost label used for reporting (default `:volDR`).
"""
function makedemandresponse(cname::String, elec::Node, capa::Union{Nothing,Number}, cost::Number, s::Snapshot; type::Symbol=:volDR)
    m = DispatchableSource(elec.carrier)
    vb = []
    if !isnothing(capa)
        push!(vb, FixedCapacity("output", energy, capa))
    end
    push!(vb, VariableCost(type, "output", energy, cost * (1-elec.losses))) # do not include demand response in losses

    c = Component(cname * " " * elec.name, m, vb)
    for t in (:virtual, :demandresponse)
        tag!(c, t)
    end
    connect!(s, c, elec)
    return c
end
