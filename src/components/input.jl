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
