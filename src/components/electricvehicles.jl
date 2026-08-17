"""
Generate electric vehicle components.
"""

using ArgCheck: @argcheck

"""
    makeEV(cname::String, yearly::Real, elec::Node, s::Snapshot;
        fixed_profile::Bool=true, smart_charging::Bool=false, vehicle_to_grid::Bool=false,
        offhours1=nothing, offhours2=nothing, minratio=nothing, days_threshold::Integer=104,
        zone::Union{Nothing,String}=nothing, techkey::String="EV",
        compensation::Real=0., gridlosses=0.,
        charging_availability=nothing, driving_profile=nothing,
        charging_eff::Union{Nothing,Real}=nothing, self_discharge::Union{Nothing,Real}=nothing, min_level_morning::Union{Nothing,Real}=nothing,
        max_charging_power_per_ev::Union{Nothing,Real}=nothing, max_dispatch_power_per_ev::Union{Nothing,Real}=nothing,
        battery_capacity_per_ev::Union{Nothing,Real}=nothing, yearly_consumption_per_ev::Union{Nothing,Real}=nothing,
    )

Build, connect and return an EV component.

Arguments:
  * `cname`: Component name prefix.
  * `yearly`: Yearly EV electricity consumption (MWh/year). Must be non-negative.
  * `elec`: Electricity node to connect EV charging/discharging flows.
  * `s`: Target snapshot where the EV component and behaviors are registered.

  * `fixed_profile`: Enable fixed-profile EV demand mode (deterministic hourly charging profile).
  * `smart_charging`: Enable flexible charging mode (charging only, no discharge to grid).
  * `vehicle_to_grid`: Enable flexible charging + grid discharge (V2G) mode.
    Exactly one of `fixed_profile`, `smart_charging`, `vehicle_to_grid` must be `true`.

  * `offhours1`: Winter off-hour indices (0-23, no duplicates). Required when `fixed_profile=true`; ignored otherwise.
  * `offhours2`: Summer off-hour indices (0-23, no duplicates). Required when `fixed_profile=true`; ignored otherwise.
  * `minratio`: Relative charging level during off-hours (`0 <= minratio <= 1`). Required when `fixed_profile=true`; ignored otherwise.
    The hourly profile is normalized so that it sums to `yearly`; a schedule
    that leaves no charging hour at all (every hour an off-hour with
    `minratio=0`) is rejected.
  * `days_threshold`: Number of first winter days before summer segment in fixed-profile assembly (`0 <= days_threshold <= 183`, used only when `fixed_profile=true`).

  * `zone`: Zone key used to read omitted EV time series in `:excel` mode.
  * `charging_availability`: Hourly charging-station availability vector or
    scalar, each value in `[0, 1]`. When omitted, read it from the workbook in
    `:excel` mode and use one in `:arguments` mode.
  * `driving_profile`: Hourly driving vector or scalar, nonnegative with a
    strictly positive sum. If `nothing`, read it from the configured
    time-series workbook.
  * `techkey`: Technology column name in the `storage` tech data sheet for EV parameters (used in flexible/V2G modes).
  * `compensation`: V2G compensation in USD/MWh applied to EV discharge output in V2G mode (ignored in non-V2G modes).
  * `gridlosses`: Optional proportional grid-loss linked flow on EV input in fixed_profile mode (`0 <= gridlosses < 1`).
  * `charging_eff`: Charging efficiency in flexible/V2G modes (`0 < charging_eff <= 1`); defaults to one in `:arguments` mode.
  * `self_discharge`: Hourly self-discharge in flexible/V2G modes (`0 <= self_discharge < 1`); defaults to zero in `:arguments` mode.
  * `min_level_morning`: Minimum morning level ratio (`0 <= min_level_morning <= 1`); defaults to zero in `:arguments` mode.
  * `max_charging_power_per_ev`: Maximum charging power per vehicle (`> 0`),
    required explicitly in `:arguments` mode.
  * `max_dispatch_power_per_ev`: Maximum dispatch power per vehicle (`>= 0`),
    required explicitly for V2G in `:arguments` mode and ignored otherwise.
  * `battery_capacity_per_ev`: Battery capacity per vehicle (`> 0`), required
    explicitly in `:arguments` mode.
  * `yearly_consumption_per_ev`: Yearly consumption per vehicle (`> 0`),
    required explicitly in `:arguments` mode.
"""
function makeEV(cname::String, yearly::Real, elec::Node, s::Snapshot; fixed_profile::Bool=true, smart_charging::Bool=false, vehicle_to_grid::Bool=false,

    # fixed-profile inputs
    offhours1=nothing, offhours2=nothing, minratio::Union{Nothing,Real}=nothing, days_threshold::Integer=104,

    # flexible / V2G inputs
    zone::Union{Nothing,String}=nothing, techkey::String="EV", compensation::Real=0., gridlosses::Real=0.,
    charging_availability=nothing, driving_profile=nothing,
    charging_eff::Union{Nothing,Real}=nothing, self_discharge::Union{Nothing,Real}=nothing, min_level_morning::Union{Nothing,Real}=nothing,
    max_charging_power_per_ev::Union{Nothing,Real}=nothing, max_dispatch_power_per_ev::Union{Nothing,Real}=nothing,
    battery_capacity_per_ev::Union{Nothing,Real}=nothing, yearly_consumption_per_ev::Union{Nothing,Real}=nothing,)
    mode_count = Int(fixed_profile) + Int(smart_charging) + Int(vehicle_to_grid)
    @argcheck mode_count == 1 "Exactly one of fixed_profile, smart_charging, vehicle_to_grid must be true."

    if fixed_profile
        @argcheck !isnothing(offhours1) "offhours1 is required when fixed_profile=true."
        @argcheck !isnothing(offhours2) "offhours2 is required when fixed_profile=true."
        @argcheck !isnothing(minratio) "minratio is required when fixed_profile=true."
        @argcheck offhours1 isa AbstractVector{<:Int} "offhours1 must be a vector of integers."
        @argcheck offhours2 isa AbstractVector{<:Int} "offhours2 must be a vector of integers."
        @argcheck 0 <= days_threshold <= 183 "days_threshold must be in [0, 183]."
        @argcheck all(0 <= h <= 23 for h in offhours1) "offhours1 must be integers between 0 and 23."
        @argcheck all(0 <= h <= 23 for h in offhours2) "offhours2 must be integers between 0 and 23."
        @argcheck allunique(offhours1) "offhours1 must not repeat an hour index."
        @argcheck allunique(offhours2) "offhours2 must not repeat an hour index."

        inputs = demand_input(yearly=yearly, gridlosses=gridlosses, minratio=minratio)
        validate_demand_input(inputs)
        _yearly = Float64(yearly)
        _gridlosses = Float64(gridlosses)
        _minratio = Float64(minratio)

        # normalizing the generated shape, rather than a separately derived
        # denominator, is what makes sum(series) == yearly by construction
        shape = vcat(
            repeat([h in offhours1 ? _minratio : 1.0 for h in 0:23], days_threshold), # winter
            repeat([h in offhours2 ? _minratio : 1.0 for h in 0:23], 182), # summer
            repeat([h in offhours1 ? _minratio : 1.0 for h in 0:23], 183 - days_threshold), # winter
        )
        shapesum = sum(shape)
        @argcheck shapesum > 0 "the EV charging schedule is empty: every hour is an off-hour and minratio is zero."
        series = shape * (_yearly / shapesum)

        m = Demand(elec.carrier, series)
        vb = Any[
            FixedJointFlow(
                "driving",
                EnergyCarrier(cname, sim(elec)),
                :output,
                series;
                mustconnect=false,
            ),
        ]
        !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x -> x[1] * _gridlosses))
        c = Component(cname * " " * elec.name, m, vb)
        tag!(c, :tech, cname)
        tag!(c, :zone, elec.name)
        for t in ("electricity", "demand", "ev")
            tag!(c, :function, t)
        end
        connect!(s, c, elec)
        return c
    else
        needs_profile_zone = timeseries_mode(s) === :excel &&
            (isnothing(charging_availability) || isnothing(driving_profile))
        @argcheck !needs_profile_zone || !isnothing(zone) "zone is required when an EV profile is read from the workbook."
        @argcheck isnothing(zone) || zone isa String "zone must be a String."
        profile_zone = isnothing(zone) ? elec.name : zone
        excel = tech_mode(s) === :excel

        # charging efficiency applies when electricity enters the battery;
        # V2G discharge and driving use the stored-energy basis directly
        eff = isnothing(charging_eff) ?
            (excel ? gettechparam(s, techkey, "charging_eff", "storage") : 1.0) : charging_eff
        # hourly self-discharge
        sd = isnothing(self_discharge) ?
            (excel ? gettechparam(s, techkey, "self_discharge", "storage") : 0.0) : self_discharge
        # min level of the average fleet battery at 7am
        min_level_ratio_morning = isnothing(min_level_morning) ?
            (excel ? gettechparam(s, techkey, "min_level_morning", "storage") : 0.0) : min_level_morning
        # assumptions about EV (per vehicle parameters from the technology workbook or overrides)
        max_charging_per_ev = if isnothing(max_charging_power_per_ev)
            excel ? gettechparam(s, techkey, "max_charging_power", "storage") : throw(ArgumentError(
                "`max_charging_power_per_ev` must be supplied in flexible EV modes when tech_mode=:arguments",
            ))
        else
            max_charging_power_per_ev
        end
        max_dispatch_per_ev = if vehicle_to_grid
            if isnothing(max_dispatch_power_per_ev)
                excel ? gettechparam(s, techkey, "max_dispatch_power", "storage") : throw(ArgumentError(
                    "`max_dispatch_power_per_ev` must be supplied when vehicle_to_grid=true and tech_mode=:arguments",
                ))
            else
                max_dispatch_power_per_ev
            end
        else
            0.0
        end
        battery_cap_per_ev = if isnothing(battery_capacity_per_ev)
            excel ? gettechparam(s, techkey, "battery_capacity", "storage") : throw(ArgumentError(
                "`battery_capacity_per_ev` must be supplied in flexible EV modes when tech_mode=:arguments",
            ))
        else
            battery_capacity_per_ev
        end
        yearly_per_ev = if isnothing(yearly_consumption_per_ev)
            excel ? gettechparam(s, techkey, "yearly_consumption", "storage") : throw(ArgumentError(
                "`yearly_consumption_per_ev` must be supplied in flexible EV modes when tech_mode=:arguments",
            ))
        else
            yearly_consumption_per_ev
        end
        inputs = demand_input(
            yearly=yearly, compensation=compensation, charging_eff=eff, self_discharge=sd,
            min_level_morning=min_level_ratio_morning, max_charging_power=max_charging_per_ev,
            max_dispatch_power=max_dispatch_per_ev, battery_capacity=battery_cap_per_ev,
            yearly_consumption=yearly_per_ev,
        )
        validate_demand_input(inputs)
        _yearly = Float64(yearly)
        _compensation = Float64(compensation)
        number_ev = _yearly / yearly_per_ev
        max_charging_power = number_ev * max_charging_per_ev
        max_dispatch_power = vehicle_to_grid ? number_ev * max_dispatch_per_ev : 0.0
        max_battery_capacity = number_ev * battery_cap_per_ev

        # profile for being connected to charging station
        charging_profile_input = isnothing(charging_availability) && timeseries_mode(s) === :arguments ?
            1.0 : charging_availability
        chargingstationprofile = _resolve_timeseries(
            s, charging_profile_input, profile_zone, "EV_charging_availability";
            keyword="charging_availability", lower=0.0, upper=1.0,
        )

        # generate consumption by applying normalized profile to yearly consumption
        if isnothing(driving_profile) && timeseries_mode(s) === :arguments
            throw(ArgumentError(
                "`driving_profile` must be supplied in flexible EV modes when timeseries_mode=:arguments",
            ))
        end
        driving = _resolve_timeseries(
            s, driving_profile, profile_zone, "EV_driving_profile";
            keyword="driving_profile", lower=0.0,
        )
        @argcheck sum(driving) > 0 "EV_driving_profile must have a strictly positive sum."
        driving = driving ./ sum(driving)
        consumption = driving * _yearly

        m = LazyStorage(elec.carrier, eff=Dict("input" => eff, "output" => 1., "driving" => 1.), self_discharge=sd, simplified=true)
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
        tag!(c, :tech, cname)
        tag!(c, :zone, elec.name)

        # level limits
        # ensure the EVs are charged enough at 7am
        @constraint(
            sim(elec).model,
            Nosy.balance(c, :level, energy, collapse=false, aggregate=true).data[8:24:end] .>= min_level_ratio_morning * max_battery_capacity * chargingstationprofile[8:24:end]
        )

        for t in ("electricity", "demand", "ev")
            tag!(c, :function, t)
        end
        vehicle_to_grid && tag!(c, :function, "generation")
        connect!(s, c, elec)

        return c
    end
end
