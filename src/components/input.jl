"""
Shared component builder input and argument validation.
"""

using ArgCheck: @argcheck

struct ComponentInputData
    overnight_cost::Union{Nothing,Number}
    lifetime::Union{Nothing,Number}
    connection_cost::Union{Nothing,Number}
    om_fixed_cost::Union{Nothing,Number}
    om_var_cost::Union{Nothing,Number}
    decommissioning::Union{Nothing,Number}
    co2_emission::Union{Nothing,Number}
    unit_size::Union{Nothing,Number}
    fuel_cost::Union{Nothing,Number}
    efficiency::Union{Nothing,Number}
    waste_cost::Union{Nothing,Number}
    gridlosses::Union{Nothing,Number}
    duration::Union{Nothing,Number}
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
        @argcheck inputs.overnight_cost isa Number "overnight_cost must be Number."
    end
    # lifetime: must be > 0 and integer-valued
    if !isnothing(inputs.lifetime)
        @argcheck inputs.lifetime isa Number "lifetime must be Number."
        @argcheck inputs.lifetime > 0 "lifetime must be > 0."
        @argcheck isinteger(inputs.lifetime) "lifetime must be integer-valued."
    end
    if !isnothing(inputs.connection_cost)
        @argcheck inputs.connection_cost isa Number "connection_cost must be Number."
    end
    if !isnothing(inputs.om_fixed_cost)
        @argcheck inputs.om_fixed_cost isa Number "om_fixed_cost must be Number."
    end
    if !isnothing(inputs.om_var_cost)
        @argcheck inputs.om_var_cost isa Number "om_var_cost must be Number."
    end
    if !isnothing(inputs.decommissioning)
        @argcheck inputs.decommissioning isa Number "decommissioning must be Number."
    end
    if !isnothing(inputs.co2_emission)
        @argcheck inputs.co2_emission isa Number "co2_emission must be Number."
    end
    if !isnothing(inputs.unit_size)
        @argcheck inputs.unit_size isa Number "unit_size must be Number."
    end
    if !isnothing(inputs.fuel_cost)
        @argcheck inputs.fuel_cost isa Number "fuel_cost must be Number."
    end
    if !isnothing(inputs.efficiency)
        @argcheck inputs.efficiency isa Number "efficiency must be Number."
        @argcheck 0 < inputs.efficiency <= 1 "efficiency must be in (0, 1]."
    end
    if !isnothing(inputs.waste_cost)
        @argcheck inputs.waste_cost isa Number "waste_cost must be Number."
    end
    if !isnothing(inputs.gridlosses)
        @argcheck inputs.gridlosses isa Number "gridlosses must be Number."
        @argcheck 0 <= inputs.gridlosses < 1 "gridlosses must be in [0, 1)."
    end
    if !isnothing(inputs.duration)
        @argcheck inputs.duration isa Number "duration must be Number."
        @argcheck inputs.duration > 0 "duration must be > 0."
    end
    return nothing
end

struct ComponentDemandInputData
    coeff::Union{Nothing,Number}
    yearlyconstant::Union{Nothing,Number}
    gridlosses::Union{Nothing,Number}
    val::Union{Nothing,Number}
    yearly::Union{Nothing,Number}
    compensation::Union{Nothing,Number}
    minratio::Union{Nothing,Number}
    charging_eff::Union{Nothing,Number}
    self_discharge::Union{Nothing,Number}
    min_level_morning::Union{Nothing,Number}
    max_charging_power::Union{Nothing,Number}
    max_dispatch_power::Union{Nothing,Number}
    battery_capacity::Union{Nothing,Number}
    yearly_consumption::Union{Nothing,Number}
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
        @argcheck inputs.coeff isa Number "coeff must be Number."
        @argcheck inputs.coeff >= 0 "coeff must be >= 0."
    end
    if !isnothing(inputs.yearlyconstant)
        @argcheck inputs.yearlyconstant isa Number "yearlyconstant must be Number."
        @argcheck inputs.yearlyconstant >= 0 "yearlyconstant must be >= 0."
    end
    if !isnothing(inputs.gridlosses)
        @argcheck inputs.gridlosses isa Number "gridlosses must be Number."
        @argcheck 0 <= inputs.gridlosses < 1 "gridlosses must be in [0, 1)."
    end
    if !isnothing(inputs.val)
        @argcheck inputs.val >= 0 "val must be >= 0."
    end
    if !isnothing(inputs.yearly)
        @argcheck inputs.yearly isa Number "yearly must be Number."
        @argcheck inputs.yearly >= 0 "yearly must be >= 0."
    end
    if !isnothing(inputs.compensation)
        @argcheck inputs.compensation isa Number "compensation must be Number or left as default."
    end
    if !isnothing(inputs.minratio)
        @argcheck inputs.minratio isa Number "minratio must be Number."
        @argcheck 0 <= inputs.minratio <= 1 "minratio must be in [0, 1]."
    end
    if !isnothing(inputs.charging_eff)
        @argcheck inputs.charging_eff isa Number "charging_eff must be Number."
        @argcheck 0 < inputs.charging_eff <= 1 "charging_eff must be in (0, 1]."
    end
    if !isnothing(inputs.self_discharge)
        @argcheck inputs.self_discharge isa Number "self_discharge must be Number."
        @argcheck 0 <= inputs.self_discharge < 1 "self_discharge must be in [0, 1)."
    end
    if !isnothing(inputs.min_level_morning)
        @argcheck inputs.min_level_morning isa Number "min_level_morning must be Number."
        @argcheck 0 <= inputs.min_level_morning <= 1 "min_level_morning must be in [0, 1]."
    end
    if !isnothing(inputs.max_charging_power)
        @argcheck inputs.max_charging_power isa Number "max_charging_power must be Number."
        @argcheck inputs.max_charging_power > 0 "max_charging_power must be > 0."
    end
    if !isnothing(inputs.max_dispatch_power)
        @argcheck inputs.max_dispatch_power isa Number "max_dispatch_power must be Number."
        @argcheck inputs.max_dispatch_power >= 0 "max_dispatch_power must be >= 0."
    end
    if !isnothing(inputs.battery_capacity)
        @argcheck inputs.battery_capacity isa Number "battery_capacity must be Number."
        @argcheck inputs.battery_capacity > 0 "battery_capacity must be > 0."
    end
    if !isnothing(inputs.yearly_consumption)
        @argcheck inputs.yearly_consumption isa Number "yearly_consumption must be Number."
        @argcheck inputs.yearly_consumption > 0 "yearly_consumption must be > 0."
    end
    return nothing
end
