"""
Generate electric vehicle components.
"""

using ArgCheck: @argcheck

"""
    makeEV(name::String, elec::Node, s::Snapshot;
        tech::String=name,
        fixed_profile::Bool=true, smart_charging::Bool=false, vehicle_to_grid::Bool=false,
        annual_consumption=nothing, offhours1=nothing, offhours2=nothing, minratio=nothing, days_threshold::Integer=104,
        number_ev=nothing, initial_connected_share=nothing,
        zone::Union{Nothing,String}=nothing, tech_column::String="EV",
        compensation::Real=0., grid_losses=0.,
        departures=nothing, arrivals=nothing,
        departure_soc=nothing, arrival_soc=nothing,
        charging_eff::Union{Nothing,Real}=nothing, self_discharge::Union{Nothing,Real}=nothing,
        max_charging_power_per_ev::Union{Nothing,Real}=nothing, max_dispatch_power_per_ev::Union{Nothing,Real}=nothing,
        battery_capacity_per_ev::Union{Nothing,Real}=nothing,
    )

Build, connect and return an EV component.

Arguments:
  * `name`: Component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `elec`: Electricity node to connect EV charging/discharging flows.
  * `s`: Target snapshot where the EV component and behaviors are registered.

  * `fixed_profile`: Enable fixed-profile EV demand mode (deterministic hourly charging profile).
  * `smart_charging`: Enable flexible charging mode (charging only, no discharge to grid).
  * `vehicle_to_grid`: Enable flexible charging + grid discharge (V2G) mode.
    Exactly one of `fixed_profile`, `smart_charging`, `vehicle_to_grid` must be `true`.

  * `annual_consumption`: Yearly EV electricity consumption in fixed-profile mode
    (MWh/year). Must be non-negative and is rejected in flexible modes.
  * `offhours1`: Winter off-hour indices (0-23, no duplicates). Required when `fixed_profile=true`; ignored otherwise.
  * `offhours2`: Summer off-hour indices (0-23, no duplicates). Required when `fixed_profile=true`; ignored otherwise.
  * `minratio`: Dimensionless charging level during off-hours
    (`0 <= minratio <= 1`). Required when `fixed_profile=true`; ignored otherwise.
    The hourly profile is normalized so that it sums to `annual_consumption`; a schedule
    that leaves no charging hour at all (every hour an off-hour with
    `minratio=0`) is rejected.
  * `days_threshold`: Number of first winter days before summer segment in fixed-profile assembly (`0 <= days_threshold <= 183`, used only when `fixed_profile=true`).

The fleet, mobility-profile, charging-efficiency, and battery-limit arguments
below are used only in flexible/V2G modes unless stated otherwise.

  * `number_ev`: Number of vehicles in the fleet (`> 0`). Scales per-vehicle
    power and battery limits.
  * `initial_connected_share`: Share of the fleet connected immediately
    before the first model timestep (`0 <= initial_connected_share <= 1`).
  * `zone`: Zone key used to read omitted EV time series in `:excel` mode.
  * `departures`: Hourly number of vehicles departing the connected fleet,
    scalar or vector, nonnegative. If `nothing`, read it from the configured
    time-series workbook (`EV_departure`).
  * `arrivals`: Hourly number of vehicles arriving to the connected fleet,
    scalar or vector, nonnegative. If `nothing`, read it from the configured
    time-series workbook (`EV_arrival`).
  * `departure_soc`: Mean SOC of departing vehicles in `[0, 1]`, scalar or vector.
    If `nothing`, read it from `EV_departure_soc` in `:excel` mode.
  * `arrival_soc`: Mean SOC of arriving vehicles in `[0, 1]`, scalar or vector.
    If `nothing`, read it from `EV_arrival_soc` in `:excel` mode.
  * `tech_column`: Technology column name in the `storage` tech data sheet for
    EV parameters, used in flexible/V2G modes; defaults to `"EV"`.
  * `compensation`: V2G compensation in currency/MWh of grid discharge
    (ignored in non-V2G modes).
  * `grid_losses`: Proportional grid-loss fraction on EV input in fixed-profile
    mode (`0 <= grid_losses < 1`).
  * `charging_eff`: Dimensionless charging efficiency in flexible/V2G modes
    (`0 < charging_eff <= 1`); defaults to one in `:arguments` mode.
  * `self_discharge`: Self-discharge fraction per hour in flexible/V2G modes
    (`0 <= self_discharge < 1`); defaults to zero in `:arguments` mode.
  * `max_charging_power_per_ev`: Maximum charging power in MW/vehicle (`> 0`),
    required explicitly in `:arguments` mode.
  * `max_dispatch_power_per_ev`: Maximum V2G power in MW/vehicle (`>= 0`),
    required explicitly for V2G in `:arguments` mode and ignored otherwise.
  * `battery_capacity_per_ev`: Battery capacity in MWh/vehicle (`> 0`), required
    explicitly in `:arguments` mode.
"""
function makeEV(name::String, elec::Node, s::Snapshot; tech::String=name,
    fixed_profile::Bool=true, smart_charging::Bool=false, vehicle_to_grid::Bool=false,
    # fixed-profile inputs
    annual_consumption::Union{Nothing,Real}=nothing, offhours1=nothing, offhours2=nothing, minratio::Union{Nothing,Real}=nothing, days_threshold::Integer=104,
    # flexible / V2G inputs
    number_ev::Union{Nothing,Real}=nothing, initial_connected_share::Union{Nothing,Real}=nothing,
    zone::Union{Nothing,String}=nothing, tech_column::String="EV", compensation::Real=0., grid_losses::Real=0.,
    departures=nothing, arrivals=nothing, departure_soc=nothing, arrival_soc=nothing,
    charging_eff::Union{Nothing,Real}=nothing, self_discharge::Union{Nothing,Real}=nothing,
    max_charging_power_per_ev::Union{Nothing,Real}=nothing, max_dispatch_power_per_ev::Union{Nothing,Real}=nothing,
    battery_capacity_per_ev::Union{Nothing,Real}=nothing,)
    mode_count = Int(fixed_profile) + Int(smart_charging) + Int(vehicle_to_grid)
    @argcheck mode_count == 1 "Exactly one of fixed_profile, smart_charging, vehicle_to_grid must be true."

    if fixed_profile
        @argcheck !isnothing(annual_consumption) "`annual_consumption` is required when fixed_profile=true."
        @argcheck isnothing(number_ev) "`number_ev` is only used in smart-charging and V2G modes."
        @argcheck isnothing(initial_connected_share) "`initial_connected_share` is only used in smart-charging and V2G modes."
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

        inputs = demand_input(annual_consumption=annual_consumption, grid_losses=grid_losses, minratio=minratio)
        validate_demand_input(inputs)
        _annual_consumption = Float64(annual_consumption)
        _grid_losses = Float64(grid_losses)
        _minratio = Float64(minratio)

        # normalizing the generated shape, rather than a separately derived
        # denominator, is what makes sum(series) == annual_consumption by construction
        shape = vcat(
            repeat([h in offhours1 ? _minratio : 1.0 for h in 0:23], days_threshold), # winter
            repeat([h in offhours2 ? _minratio : 1.0 for h in 0:23], 182), # summer
            repeat([h in offhours1 ? _minratio : 1.0 for h in 0:23], 183 - days_threshold), # winter
        )
        shapesum = sum(shape)
        @argcheck shapesum > 0 "the EV charging schedule is empty: every hour is an off-hour and minratio is zero."
        series = shape * (_annual_consumption / shapesum)

        m = Demand(elec.carrier, series)
        vb = Any[
            FixedJointFlow(
                "driving",
                EnergyCarrier(name, sim(elec)),
                :output,
                series;
                mustconnect=false,
            ),
        ]
        !iszero(_grid_losses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x -> x[1] * _grid_losses))
        c = Component(name * " " * elec.name, m, vb)
        tag!(c, :tech, tech)
        tag!(c, :zone, elec.name)
        for t in ("electricity", "demand", "ev")
            tag!(c, :function, t)
        end
        connect!(s, c, elec)
        return c
    else
        @argcheck !isnothing(number_ev) "`number_ev` is required in smart-charging and V2G modes."
        @argcheck !isnothing(initial_connected_share) "`initial_connected_share` is required in smart-charging and V2G modes."
        @argcheck isnothing(annual_consumption) "`annual_consumption` is only used in fixed_profile mode."

        needs_profile_zone = timeseries_mode(s) === :excel && (
            isnothing(departures) || isnothing(arrivals) ||
            isnothing(departure_soc) || isnothing(arrival_soc)
        )
        @argcheck !needs_profile_zone || !isnothing(zone) "zone is required when an EV profile is read from the workbook."
        @argcheck isnothing(zone) || zone isa String "zone must be a String."
        profile_zone = isnothing(zone) ? elec.name : zone
        excel = tech_mode(s) === :excel

        # charging efficiency applies when electricity enters the battery;
        # V2G discharge, departure and arrival use the stored-energy basis directly
        eff = isnothing(charging_eff) ?
            (excel ? gettechparam(s, tech_column, "charging_eff", "storage") : 1.0) : charging_eff
        # hourly self-discharge
        sd = isnothing(self_discharge) ?
            (excel ? gettechparam(s, tech_column, "self_discharge", "storage") : 0.0) : self_discharge
        # assumptions about EV (per vehicle parameters from the technology workbook or overrides)
        max_charging_per_ev = if isnothing(max_charging_power_per_ev)
            excel ? gettechparam(s, tech_column, "max_charging_power", "storage") : throw(ArgumentError(
                "`max_charging_power_per_ev` must be supplied in flexible EV modes when tech_mode=:arguments",
            ))
        else
            max_charging_power_per_ev
        end
        max_dispatch_per_ev = if vehicle_to_grid
            if isnothing(max_dispatch_power_per_ev)
                excel ? gettechparam(s, tech_column, "max_dispatch_power", "storage") : throw(ArgumentError(
                    "`max_dispatch_power_per_ev` must be supplied when vehicle_to_grid=true and tech_mode=:arguments",
                ))
            else
                max_dispatch_power_per_ev
            end
        else
            0.0
        end
        battery_cap_per_ev = if isnothing(battery_capacity_per_ev)
            excel ? gettechparam(s, tech_column, "battery_capacity", "storage") : throw(ArgumentError(
                "`battery_capacity_per_ev` must be supplied in flexible EV modes when tech_mode=:arguments",
            ))
        else
            battery_capacity_per_ev
        end
        inputs = demand_input(
            number_ev=number_ev, initial_connected_share=initial_connected_share,
            compensation=compensation, charging_eff=eff, self_discharge=sd,
            max_charging_power=max_charging_per_ev,
            max_dispatch_power=max_dispatch_per_ev, battery_capacity=battery_cap_per_ev,
        )
        validate_demand_input(inputs)
        _number_ev = Float64(number_ev)
        _compensation = Float64(compensation)
        _initial_connected_share = Float64(initial_connected_share)
        _battery_capacity_per_ev = Float64(battery_cap_per_ev)
        max_charging_power = _number_ev * max_charging_per_ev
        max_dispatch_power = vehicle_to_grid ? _number_ev * max_dispatch_per_ev : 0.0
        max_battery_capacity = _number_ev * _battery_capacity_per_ev

        n_dep = _resolve_timeseries(
            s, departures, profile_zone, "EV_departure";
            keyword="departures", lower=0.0,
        )
        n_arr = _resolve_timeseries(
            s, arrivals, profile_zone, "EV_arrival";
            keyword="arrivals", lower=0.0,
        )
        soc_dep = _resolve_timeseries(
            s, departure_soc, profile_zone, "EV_departure_soc";
            keyword="departure_soc", lower=0.0, upper=1.0,
        )
        soc_arr = _resolve_timeseries(
            s, arrival_soc, profile_zone, "EV_arrival_soc";
            keyword="arrival_soc", lower=0.0, upper=1.0,
        )

        # on a circular mesh, annual `departures` and `arrivals` must balance
        @argcheck isapprox(sum(n_dep), sum(n_arr); rtol=0, atol=1e-6) "EV `departures` and `arrivals` must balance over the circular time mesh."
        # connected fleet at the start of each hour
        n_conn = Vector{Float64}(undef, length(n_dep))
        n_conn[1] = _initial_connected_share * _number_ev
        for t in 1:length(n_conn) - 1
            n_conn[t + 1] = n_conn[t] - n_dep[t] + n_arr[t]
            @argcheck 0 <= n_conn[t + 1] <= _number_ev "connected vehicle count at hour $(t + 1) must be in [0, $_number_ev], got $(n_conn[t + 1])."
        end

        # availability at hour t uses the connected fleet at the start of that hour
        chargingstationprofile = n_conn ./ _number_ev
        departing = n_dep .* soc_dep .* _battery_capacity_per_ev
        arriving = n_arr .* soc_arr .* _battery_capacity_per_ev

        m = LazyStorage(elec.carrier, eff=Dict("input" => eff, "output" => 1., "departure" => 1., "arrival" => 1., "driving" => 0.), self_discharge=sd, simplified=true)
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

        # departure / arrival: fixed series, no capacity
        push!(vb, FixedJointFlow("departure", EnergyCarrier(name, sim(elec)), :output, departing, mustconnect=false)) # this port does not need connection
        push!(vb, FixedJointFlow("arrival", EnergyCarrier(name, sim(elec)), :input, arriving, mustconnect=false)) # this port does not need connection
        # output - driving: net driving (departure - arrival), reporting only (eff=0)
        push!(vb, FixedJointFlow("driving", EnergyCarrier(name, sim(elec)), :output, departing .- arriving, mustconnect=false))

        c = Component(name * " " * elec.name, m, vb)
        tag!(c, :tech, tech)
        tag!(c, :zone, elec.name)

        for t in ("electricity", "demand", "ev")
            tag!(c, :function, t)
        end
        vehicle_to_grid && tag!(c, :function, "generation")
        connect!(s, c, elec)

        return c
    end
end
