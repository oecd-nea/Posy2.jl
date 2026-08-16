"""
Shared component builder input and argument validation.
"""

using ArgCheck: @argcheck

struct ComponentInputData
    overnight_cost::Union{Nothing,Real}
    lifetime::Union{Nothing,Real}
    connection_cost::Union{Nothing,Real}
    om_fixed_cost::Union{Nothing,Real}
    om_var_cost::Union{Nothing,Real}
    decommissioning::Union{Nothing,Real}
    co2_emission::Union{Nothing,Real}
    unit_size::Union{Nothing,Real}
    fuel_cost::Union{Nothing,Real}
    efficiency::Union{Nothing,Real}
    waste_cost::Union{Nothing,Real}
    gridlosses::Union{Nothing,Real}
    duration::Union{Nothing,Real}
end

function component_input(;
    overnight_cost=nothing, lifetime=nothing, connection_cost=nothing,
    om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing,
    co2_emission=nothing, unit_size=nothing, fuel_cost=nothing, efficiency=nothing,
    waste_cost=nothing, gridlosses=nothing, duration=nothing,
)
    return ComponentInputData(
        overnight_cost, lifetime, connection_cost, om_fixed_cost, om_var_cost, decommissioning,
        co2_emission, unit_size, fuel_cost, efficiency, waste_cost, gridlosses, duration,
    )
end

"""
    validate_component_input(inputs::ComponentInputData)

Validate only the fields present in `inputs`.
Fields set to `nothing` are skipped.
"""
function validate_component_input(inputs::ComponentInputData)
    if !isnothing(inputs.overnight_cost)
        @argcheck inputs.overnight_cost isa Real "overnight_cost must be Real."
    end
    # lifetime: must be > 0 and integer-valued
    if !isnothing(inputs.lifetime)
        @argcheck inputs.lifetime isa Real "lifetime must be Real."
        @argcheck inputs.lifetime > 0 "lifetime must be > 0."
        @argcheck isinteger(inputs.lifetime) "lifetime must be integer-valued."
    end
    if !isnothing(inputs.connection_cost)
        @argcheck inputs.connection_cost isa Real "connection_cost must be Real."
    end
    if !isnothing(inputs.om_fixed_cost)
        @argcheck inputs.om_fixed_cost isa Real "om_fixed_cost must be Real."
    end
    if !isnothing(inputs.om_var_cost)
        @argcheck inputs.om_var_cost isa Real "om_var_cost must be Real."
    end
    if !isnothing(inputs.decommissioning)
        @argcheck inputs.decommissioning isa Real "decommissioning must be Real."
    end
    if !isnothing(inputs.co2_emission)
        @argcheck inputs.co2_emission isa Real "co2_emission must be Real."
    end
    if !isnothing(inputs.unit_size)
        @argcheck inputs.unit_size isa Real "unit_size must be Real."
    end
    if !isnothing(inputs.fuel_cost)
        @argcheck inputs.fuel_cost isa Real "fuel_cost must be Real."
    end
    if !isnothing(inputs.efficiency)
        @argcheck inputs.efficiency isa Real "efficiency must be Real."
        @argcheck 0 < inputs.efficiency <= 1 "efficiency must be in (0, 1]."
    end
    if !isnothing(inputs.waste_cost)
        @argcheck inputs.waste_cost isa Real "waste_cost must be Real."
    end
    if !isnothing(inputs.gridlosses)
        @argcheck inputs.gridlosses isa Real "gridlosses must be Real."
        @argcheck 0 <= inputs.gridlosses < 1 "gridlosses must be in [0, 1)."
    end
    if !isnothing(inputs.duration)
        @argcheck inputs.duration isa Real "duration must be Real."
        @argcheck inputs.duration > 0 "duration must be > 0."
    end
    return nothing
end

"""
    gencapacity(cap, pname, s, compname; kwargs...)

Resolve one capacity argument and return the matching capacity behavior.

`cap` is `nothing` (optimize), a `Real` (fix), a JuMP `VariableRef`/`AffExpr`
(reuse that expression), or a `Snapshot` (inherit the capacity of `compname` in
it). `mincap`/`maxcap` bound an optimized or reused capacity, and are checked as
assertions against a fixed or inherited one. `argname` names the capacity
argument in error messages.
"""
function gencapacity(cap, pname::String, s::Snapshot, compname::String;
    mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    unitsize::Union{Nothing,Real}=nothing, integer::Bool=false,
    warmstart::Union{Nothing,Real}=nothing, argname::String="cap",
)
    if cap isa Snapshot
        val = _inheritedcapacity(cap, compname, pname, argname)
        _checkcapacitybounds(val, mincap, maxcap, argname)
        return FixedCapacity(pname, energy, val, unitsize=unitsize)
    elseif cap isa Real
        _checkcapacitybounds(cap, mincap, maxcap, argname)
        return FixedCapacity(pname, energy, cap, unitsize=unitsize)
    elseif cap isa VariableRef || cap isa AffExpr
        JuMP.check_belongs_to_model(cap, Nosy.uppermodel(sim(s)))
        return VariableCapacity(
            pname, energy;
            expression=cap, unitsize=unitsize, integer=integer, warmstart=warmstart,
            lb=isnothing(mincap) ? 0.0 : mincap, ub=isnothing(maxcap) ? Inf : maxcap,
        )
    else
        return VariableCapacity(
            pname, energy;
            unitsize=unitsize, integer=integer, warmstart=warmstart,
            lb=isnothing(mincap) ? 0.0 : mincap, ub=isnothing(maxcap) ? Inf : maxcap,
        )
    end
end

"""
    _inheritsource(ini, compname, pname, argname)

Return the component of `ini` that `argname` inherits from, checking that the
snapshot is extracted, holds that component, and that the component has the
port. Every message names the argument, the component and the port.
"""
function _inheritsource(ini::Snapshot, compname::String, pname::String, argname::String)
    # inheriting reads solved values; an unextracted snapshot still holds expressions
    ini isa Snapshot{Float64} || throw(ArgumentError(
        "`$argname` was given a snapshot that is not extracted, so the solved value " *
        "of component \"$compname\" port \"$pname\" is still a JuMP expression. " *
        "Pass `extract(snapshot)` instead.",
    ))
    Nosy.hascomponent(ini, compname) || throw(ArgumentError(
        "`$argname` was given a snapshot with no component named \"$compname\" to " *
        "inherit port \"$pname\" from. Use the same component prefix and node name " *
        "as in the source snapshot.",
    ))
    source = Nosy.getcomponent(ini, compname)
    Nosy.hasport(source, pname) || throw(ArgumentError(
        "`$argname` was given a snapshot whose component \"$compname\" has no " *
        "port named \"$pname\": it is not the same kind of component.",
    ))
    return source
end

function _inheritedcapacity(ini::Snapshot, compname::String, pname::String, argname::String)
    # per port, so that a component holding several capacities inherits each one
    val = capacity(_inheritsource(ini, compname, pname, argname), pname)
    isfinite(val) || throw(ArgumentError(
        "`$argname` was given a snapshot whose component \"$compname\" has no " *
        "capacity on port \"$pname\" to inherit.",
    ))
    return val
end

function _checkcapacitybounds(val::Real, mincap, maxcap, argname::String)
    if !isnothing(mincap)
        @argcheck val >= mincap "`$argname` is fixed at $val, below `$(replace(argname, "cap" => "mincap"))` = $mincap."
    end
    if !isnothing(maxcap)
        @argcheck val <= maxcap "`$argname` is fixed at $val, above `$(replace(argname, "cap" => "maxcap"))` = $maxcap."
    end
    return nothing
end

"""
    _pushinheriteduc!(vb, ini, compname, pname)

Push the commitment schedule solved for port `pname` of `compname` in `ini` as a
unit commitment behavior, replaying its startup, shutdown and state series.
"""
function _pushinheriteduc!(vb, ini::Snapshot, compname::String, pname::String)
    source = _inheritsource(ini, compname, pname, "uc")
    behaviors = Nosy.getbehaviors(source, Nosy.FleetUnitCommitmentBehavior)
    isempty(behaviors) && throw(ArgumentError(
        "`uc` was given a snapshot whose component \"$compname\" carries no unit " *
        "commitment behavior on port \"$pname\" to replay.",
    ))
    push!(vb, UnitCommitment(first(behaviors)))
    return nothing
end

"""
    _ucenabled(uc)

Return whether unit commitment is modeled, for `uc` being a `Bool` or a `Snapshot`.
"""
_ucenabled(uc) = uc isa Snapshot || uc === true

"""
    _checkucsource(uc, cap, capname)

A replayed commitment schedule counts units of the source fleet, so it is only
meaningful against a capacity fixed to that same fleet.
"""
function _checkucsource(uc, cap, capname::String="cap")
    if uc isa Snapshot && !(cap isa Real || cap isa Snapshot)
        throw(ArgumentError(
            "`uc` replays a solved commitment schedule and requires a fixed capacity: " *
            "pass `$capname` as a number or as the same snapshot.",
        ))
    end
    return nothing
end

struct ComponentDemandInputData
    coeff::Union{Nothing,Real}
    yearlyconstant::Union{Nothing,Real}
    gridlosses::Union{Nothing,Real}
    val::Union{Nothing,Real}
    yearly::Union{Nothing,Real}
    compensation::Union{Nothing,Real}
    minratio::Union{Nothing,Real}
    charging_eff::Union{Nothing,Real}
    self_discharge::Union{Nothing,Real}
    min_level_morning::Union{Nothing,Real}
    max_charging_power::Union{Nothing,Real}
    max_dispatch_power::Union{Nothing,Real}
    battery_capacity::Union{Nothing,Real}
    yearly_consumption::Union{Nothing,Real}
end

function demand_input(;
    coeff=nothing, yearlyconstant=nothing, gridlosses=nothing, val=nothing, yearly=nothing,
    compensation=nothing, minratio=nothing, charging_eff=nothing, self_discharge=nothing,
    min_level_morning=nothing, max_charging_power=nothing, max_dispatch_power=nothing,
    battery_capacity=nothing, yearly_consumption=nothing,
)
    return ComponentDemandInputData(
        coeff, yearlyconstant, gridlosses, val, yearly, compensation, minratio, charging_eff,
        self_discharge, min_level_morning, max_charging_power, max_dispatch_power,
        battery_capacity, yearly_consumption,
    )
end

"""
    validate_demand_input(inputs::ComponentDemandInputData)

Validate only the fields present in `inputs`.
Fields set to `nothing` are skipped.
"""
function validate_demand_input(inputs::ComponentDemandInputData)
    if !isnothing(inputs.coeff)
        @argcheck inputs.coeff isa Real "coeff must be Real."
        @argcheck inputs.coeff >= 0 "coeff must be >= 0."
    end
    if !isnothing(inputs.yearlyconstant)
        @argcheck inputs.yearlyconstant isa Real "yearlyconstant must be Real."
        @argcheck inputs.yearlyconstant >= 0 "yearlyconstant must be >= 0."
    end
    if !isnothing(inputs.gridlosses)
        @argcheck inputs.gridlosses isa Real "gridlosses must be Real."
        @argcheck 0 <= inputs.gridlosses < 1 "gridlosses must be in [0, 1)."
    end
    if !isnothing(inputs.val)
        @argcheck inputs.val >= 0 "val must be >= 0."
    end
    if !isnothing(inputs.yearly)
        @argcheck inputs.yearly isa Real "yearly must be Real."
        @argcheck inputs.yearly >= 0 "yearly must be >= 0."
    end
    if !isnothing(inputs.compensation)
        @argcheck inputs.compensation isa Real "compensation must be Real or left as default."
    end
    if !isnothing(inputs.minratio)
        @argcheck inputs.minratio isa Real "minratio must be Real."
        @argcheck 0 <= inputs.minratio <= 1 "minratio must be in [0, 1]."
    end
    if !isnothing(inputs.charging_eff)
        @argcheck inputs.charging_eff isa Real "charging_eff must be Real."
        @argcheck 0 < inputs.charging_eff <= 1 "charging_eff must be in (0, 1]."
    end
    if !isnothing(inputs.self_discharge)
        @argcheck inputs.self_discharge isa Real "self_discharge must be Real."
        @argcheck 0 <= inputs.self_discharge < 1 "self_discharge must be in [0, 1)."
    end
    if !isnothing(inputs.min_level_morning)
        @argcheck inputs.min_level_morning isa Real "min_level_morning must be Real."
        @argcheck 0 <= inputs.min_level_morning <= 1 "min_level_morning must be in [0, 1]."
    end
    if !isnothing(inputs.max_charging_power)
        @argcheck inputs.max_charging_power isa Real "max_charging_power must be Real."
        @argcheck inputs.max_charging_power > 0 "max_charging_power must be > 0."
    end
    if !isnothing(inputs.max_dispatch_power)
        @argcheck inputs.max_dispatch_power isa Real "max_dispatch_power must be Real."
        @argcheck inputs.max_dispatch_power >= 0 "max_dispatch_power must be >= 0."
    end
    if !isnothing(inputs.battery_capacity)
        @argcheck inputs.battery_capacity isa Real "battery_capacity must be Real."
        @argcheck inputs.battery_capacity > 0 "battery_capacity must be > 0."
    end
    if !isnothing(inputs.yearly_consumption)
        @argcheck inputs.yearly_consumption isa Real "yearly_consumption must be Real."
        @argcheck inputs.yearly_consumption > 0 "yearly_consumption must be > 0."
    end
    return nothing
end
