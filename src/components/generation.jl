"""
Generate generation-side components.
"""

using ArgCheck: @argcheck

"""
    makeflathydrogenpurchase(cname::String, n::Node, val::Number, s::Snapshot)

Build, connect and return a flat hydrogen purchase component.

Arguments:
  * cname: component name prefix.
  * n: hydrogen node to connect the component to.
  * val: yearly purchased hydrogen amount, converted internally to a flat hourly capacity (`val / 8760`).
  * s: snapshot to register the component in.
"""
function makeflathydrogenpurchase(cname::String, n::Node, val::Number, s::Snapshot)
    m = ProfileSource(n.carrier, 1.)
    vb = []
    push!(vb, FixedCapacity("output", energy, val/8760))
    c = Component(cname * " " * n.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, n.name)
    for t in ("hydrogen", "purchase")
        tag!(c, :function, t)
    end
    connect!(s, c, n)
    return c
end

"""
    makedispatchable(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing, capacitymultiplier=nothing,
        integeruc=false, uc=false, fuelnode=nothing,
        co2price=co2_price(s),
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing, decommissioning::Union{Nothing,Number}=nothing,
        lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing, connection_cost::Union{Nothing,Number}=nothing,
        om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing, no_load_cost::Union{Nothing,Number}=nothing,
        startup_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing, efficiency::Union{Nothing,Number}=nothing,
        unit_size::Union{Nothing,Number}=nothing, ramp_up::Union{Nothing,Number}=nothing, ramp_down::Union{Nothing,Number}=nothing,
        min_power::Union{Nothing,Number}=nothing, min_uptime::Union{Nothing,Number}=nothing,
        min_downtime::Union{Nothing,Number}=nothing, startup_duration::Union{Nothing,Number}=nothing, shutdown_duration::Union{Nothing,Number}=nothing,
    )

Build, connect and return a dispatchable component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `dispatchable` tech data sheet.
  * elec: Electricity node connected to component output flow.
  * co2: CO2 node connected only when `co2_emission != 0`.
  * s: Target snapshot where the component and behaviors are registered.

  * cap: Fixed output capacity in model power units. If `0`, the function returns `nothing`. If `nothing`, output capacity is a decision variable.
  * mincap: Lower/upper bounds for variable capacity when `cap === nothing`.
  * maxcap: Lower/upper bounds for variable capacity when `cap === nothing`.
  * ini: Optional initial snapshot. If provided, capacity/UC state is inherited from the matching component.
  * capacitymultiplier: Time varying multiplier applied to output capacity (capacity basis, not energy basis).

  * integeruc: If `true`, UC commitment variables are integer (mixed integer UC).
  * uc: Enables UC constraints and UC linked costs (`no_load_cost`, `startup_cost`).
  * fuelnode: If provided, fuel is modeled as an input flow linked by efficiency. If `nothing`, fuel is modeled as a variable cost on output energy (`fuel_cost`).

  * co2price: CO2 cost coefficient used with emitted CO2 flow.

  * overnight_cost: Overnight CAPEX input used by `eac(...)` (Excel default when `nothing`).
  * om_fixed_cost: Fixed O&M cost on output capacity (`FixedCost(:fom, "output", ...)`; Excel default when `nothing`).
  * decommissioning: Decommissioning cost ratio used in `decom_cost(...)` (Excel default when `nothing`).
  * lifetime: Asset lifetime used by annualization/decommissioning calculations (`> 0`, integer-valued).
  * construction_profile: Construction cost share profile passed to `eac(...)` (Excel default when `nothing`).
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)` (Excel default when `nothing`).
  * connection_cost: Connection cost ratio applied on annualized investment.
  * om_var_cost: Variable O&M cost on output energy flow (`VariableCost(:vom, "output", ...)`).
  * fuel_cost: Direct fuel variable cost on output energy. Used only when `fuelnode === nothing`.
  * no_load_cost: UC no load cost applied per committed output state and time step. Used only when `uc=true`.
  * startup_cost: UC startup cost applied to startup events. Used only when `uc=true`.
  * co2_emission: CO2 emission factor linked from output energy to CO2 flow (`output * co2_emission / 1000`).
  * efficiency: Fuel to output conversion efficiency for linked fuel flow. Required when `fuelnode` is provided.
  * unit_size: Unit block size for discrete capacity representation. `0` is treated as no unit size constraint.
  * ramp_up: Max ramp up as a fraction of unit capacity per hour. Passed to `Ramping(...)` as `ramp_up * unit_size`. Excel default when `nothing`. Used only when `unit_size > 0`.
  * ramp_down: Max ramp down as a fraction of unit capacity per hour. Same scaling as `ramp_up`. Excel default when `nothing`. Used only when `unit_size > 0`.
  * min_power: UC minimum generation fraction while committed. Used only when `uc=true`.
  * min_uptime: UC minimum uptime constraint. Used only when `uc=true`.
  * min_downtime: UC minimum downtime constraint. Used only when `uc=true`.
  * startup_duration: UC startup duration parameter. Used only when `uc=true`.
  * shutdown_duration: UC shutdown duration parameter. Used only when `uc=true`.
"""
function makedispatchable(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap=nothing, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, capacitymultiplier=nothing,

    # unit commitment / operation
    integeruc=false, uc=false, fuelnode=nothing,

    co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing,
    no_load_cost::Union{Nothing,Number}=nothing, startup_cost::Union{Nothing,Number}=nothing,
    co2_emission::Union{Nothing,Number}=nothing, efficiency::Union{Nothing,Number}=nothing, unit_size::Union{Nothing,Number}=nothing,
    ramp_up::Union{Nothing,Number}=nothing, ramp_down::Union{Nothing,Number}=nothing,
    min_power::Union{Nothing,Number}=nothing, min_uptime::Union{Nothing,Number}=nothing,
    min_downtime::Union{Nothing,Number}=nothing, startup_duration::Union{Nothing,Number}=nothing, shutdown_duration::Union{Nothing,Number}=nothing,
)
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "dispatchable") : connection_cost
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    _usize_raw = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    _fuel = isnothing(fuelnode) ? (isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost) : nothing
    _eff = isnothing(fuelnode) ? nothing : (isnothing(efficiency) ? gettechparam(s, tech, "efficiency", "dispatchable") : efficiency)
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, decommissioning=_decom, co2_emission=_co2_em, unit_size=_usize_raw,
        fuel_cost=_fuel, efficiency=_eff,
    )
    validate_component_input(inputs)

    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "dispatchable") : decommissioning_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    
    # capacity multiplier
    if !isnothing(capacitymultiplier)
        push!(vb, CapacityMultiplier("output", capacitymultiplier))
    end

    # fuel cost only used is fuel node is nothing
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    if iszero(_usize_raw)
        _usize = nothing
    else
        @argcheck _usize_raw > 0 "unit_size must be > 0 when non-zero."
        _usize = _usize_raw
    end
    if cap isa Number
        if !iszero(cap)
            push!(vb, FixedCapacity("output", energy, cap, unitsize=_usize))
        else
            # component not created
            return nothing
        end
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, unitsize=_usize, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("output", energy, capacity(ini, cname * " " * elec.name), unitsize=_usize))
        end
    end

    # fuel node management
    if isnothing(fuelnode)
        push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    else
        _eff = Float64(_eff)
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x[1] / _eff))
    end

    if uc
        if isnothing(ini)
            _min_power = isnothing(min_power) ? gettechparam(s, tech, "min_power", "dispatchable") : min_power
            _min_uptime = isnothing(min_uptime) ? gettechparam(s, tech, "min_uptime", "dispatchable") : min_uptime
            _min_downtime = isnothing(min_downtime) ? gettechparam(s, tech, "min_downtime", "dispatchable") : min_downtime
            _startup_dur = isnothing(startup_duration) ? gettechparam(s, tech, "startup_duration", "dispatchable") : startup_duration
            _shutdown_dur = isnothing(shutdown_duration) ? gettechparam(s, tech, "shutdown_duration", "dispatchable") : shutdown_duration
            @argcheck _min_power isa Number "min_power must be Number."
            @argcheck _min_uptime isa Number "min_uptime must be Number."
            @argcheck _min_downtime isa Number "min_downtime must be Number."
            @argcheck _startup_dur isa Number "startup_duration must be Number."
            @argcheck _shutdown_dur isa Number "shutdown_duration must be Number."
            push!(vb, UnitCommitment("output", 
                _min_power, 
                uptime=_min_uptime, 
                downtime=_min_downtime, 
                startup=_startup_dur, 
                shutdown=_shutdown_dur, 
                integer=integeruc)
            )
        else
            push!(vb, UnitCommitment(first(Nosy.getbehaviors(ini.components[cname * " " * elec.name], Nosy.FleetUnitCommitmentBehavior))))
        end
        _noload = isnothing(no_load_cost) ? gettechparam(s, tech, "no_load_cost", "dispatchable") : no_load_cost
        _startup = isnothing(startup_cost) ? gettechparam(s, tech, "startup_cost", "dispatchable") : startup_cost
        @argcheck _noload isa Number "no_load_cost must be Number."
        @argcheck _startup isa Number "startup_cost must be Number."
        push!(vb, NoLoadCost(:noload, "output", _noload))
        push!(vb, StartupCost(:startup, "output", _startup))
    end

    if !isnothing(_usize)
        _ru = isnothing(ramp_up) ? gettechparam(s, tech, "ramp_up", "dispatchable") : ramp_up
        _rd = isnothing(ramp_down) ? gettechparam(s, tech, "ramp_down", "dispatchable") : ramp_down
        @argcheck _ru isa Number "ramp_up must be Number."
        @argcheck _rd isa Number "ramp_down must be Number."
        @argcheck _ru >= 0 "ramp_up must be non negative."
        @argcheck _rd >= 0 "ramp_down must be non negative."
        if !iszero(_ru)
            push!(vb, Ramping("output", :up, _ru * _usize, energy))
        end
        if !iszero(_rd)
            push!(vb, Ramping("output", :down, _rd * _usize, energy))
        end
    end

    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    for t in ("generation", "dispatchable")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    if !isnothing(fuelnode)
        connect!(s, c, fuelnode)
    end
    return c
end

"""
    makenuclear(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, integercap=false, ini=nothing, warmstart=nothing,
        uc=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,
        reload_duration::Union{Nothing,Number}=nothing, reloadmask::Union{Nothing,Number}=nothing, reload_fraction_per_year::Union{Nothing,Number}=nothing,
        fuelnode=nothing, co2price=co2_price(s),
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing,
        waste_cost::Union{Nothing,Number}=nothing, no_load_cost::Union{Nothing,Number}=nothing, startup_cost::Union{Nothing,Number}=nothing,
        co2_emission::Union{Nothing,Number}=nothing, efficiency::Union{Nothing,Number}=nothing, unit_size::Union{Nothing,Number}=nothing,
        min_power::Union{Nothing,Number}=nothing, min_uptime::Union{Nothing,Number}=nothing, min_downtime::Union{Nothing,Number}=nothing,
        startup_duration::Union{Nothing,Number}=nothing, shutdown_duration::Union{Nothing,Number}=nothing,
    )

Build, connect and return a nuclear reactor component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `dispatchable` tech data sheet.
  * elec: electricity node to connect the component to.
  * co2: CO2 node connected when `co2_emission` is non zero.
  * s: snapshot to register the component in.

  * cap: Fixed output capacity. If `nothing`, capacity can be optimized with optional bounds.
  * mincap: Bounds applied when `cap === nothing`.
  * maxcap: Bounds applied when `cap === nothing`.
  * integercap: Integer flag for capacity expansion variable.
  * ini: Optional initial snapshot for inherited capacity/UC settings.
  * warmstart: Warm start value passed to variable capacity behavior when used.

  * uc: Enables UC constraints and UC linked costs. Reloading logic is only modeled when `uc=true`; if `uc=false` and any reloading argument is provided, a warning is emitted and reloading is ignored.
  * integeruc: Integer UC commitment variables.
  * startupmask: Optional masks restricting UC startup/shutdown availability over time.
  * shutdownmask: Optional masks restricting UC startup/shutdown availability over time.

  * reload_duration: Duration of planned reload outage. If `nothing`, read from Excel. Must be >= 0; reloading constraints are enabled only when this value is > 0.
  * reloadmask: Interval between allowed reload windows. Non default parameter (not read from Excel). When reloading is enabled, it must be provided , strictly positive, and integer-valued.
  * reload_fraction_per_year: Minimum yearly reload requirement (fraction per unit per year). If `nothing`, read from Excel. Must be >= 0; reloading constraints are enabled only when this value is > 0.

  * fuelnode: If provided, fuel is represented as linked input flow using `efficiency`. If `nothing`, `fuel_cost` is applied as output variable cost.
  * co2price: CO2 price coefficient for emitted CO2 flow.

  * overnight_cost: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * decommissioning: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * lifetime: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms (`> 0`, integer-valued). Excel defaults are used when values are `nothing`.
  * construction_profile: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. Excel defaults are used when values are `nothing`.
  * connection_cost: Ratio applied to annualized investment for connection cost.
  * om_var_cost: Variable cost coefficients on output energy (fuel cost used directly only when `fuelnode === nothing`).
  * fuel_cost: Variable cost coefficients on output energy (fuel cost used directly only when `fuelnode === nothing`).
  * waste_cost: Variable cost coefficients on output energy (fuel cost used directly only when `fuelnode === nothing`).
  * no_load_cost: UC specific costs added only when `uc=true`.
  * startup_cost: UC specific costs added only when `uc=true`.
  * co2_emission: Emission factor linking output energy to CO2 output flow.
  * efficiency: Fuel to output efficiency for linked fuel input mode.
  * unit_size: Unit block size for discrete capacity representation.
  * min_power: UC operating constraints and transition timing parameters (used only when `uc=true`).
  * min_uptime: UC operating constraints and transition timing parameters (used only when `uc=true`).
  * min_downtime: UC operating constraints and transition timing parameters (used only when `uc=true`).
  * startup_duration: UC operating constraints and transition timing parameters (used only when `uc=true`).
  * shutdown_duration: UC operating constraints and transition timing parameters (used only when `uc=true`).
"""
function makenuclear(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap=nothing, mincap=nothing, maxcap=nothing, integercap=false, ini::Union{Nothing,Snapshot}=nothing, warmstart=nothing,

    # unit commitment / operation
    uc=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,

    # reloading controls
    reload_duration::Union{Nothing,Number}=nothing, reloadmask::Union{Nothing,Number}=nothing, reload_fraction_per_year::Union{Nothing,Number}=nothing,

    # external nodes / prices
    fuelnode=nothing, co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing,
    waste_cost::Union{Nothing,Number}=nothing, no_load_cost::Union{Nothing,Number}=nothing,
    startup_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing, efficiency::Union{Nothing,Number}=nothing,
    unit_size::Union{Nothing,Number}=nothing, min_power::Union{Nothing,Number}=nothing,
    min_uptime::Union{Nothing,Number}=nothing, min_downtime::Union{Nothing,Number}=nothing,
    startup_duration::Union{Nothing,Number}=nothing, shutdown_duration::Union{Nothing,Number}=nothing,
)
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "dispatchable") : connection_cost
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    _waste = isnothing(waste_cost) ? gettechparam(s, tech, "waste_cost", "dispatchable") : waste_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    _usize_raw = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    _fuel = isnothing(fuelnode) ? (isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost) : nothing
    _eff = isnothing(fuelnode) ? nothing : (isnothing(efficiency) ? gettechparam(s, tech, "efficiency", "dispatchable") : efficiency)
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, waste_cost=_waste, decommissioning=_decom, co2_emission=_co2_em,
        unit_size=_usize_raw, fuel_cost=_fuel, efficiency=_eff,
    )
    validate_component_input(inputs)

    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "dispatchable") : decommissioning_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    push!(vb, VariableCost(:waste, "output", energy, _waste))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    if iszero(_usize_raw)
        _usize = nothing
    else
        @argcheck _usize_raw > 0 "unit_size must be > 0 when non-zero."
        _usize = _usize_raw
    end
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap, unitsize=_usize))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, unitsize=_usize, integer=integercap, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap, warmstart=warmstart))
        elseif Nosy.hascomponent(ini, cname * " " * elec.name)
            push!(vb, FixedCapacity("output", energy, capacity(ini, cname * " " * elec.name), unitsize=_usize))
        else
            push!(vb, FixedCapacity("output", energy, 0., unitsize=_usize))
        end
    end

    # fuel node management
    # fuel cost only used if fuel node is nothing
    if isnothing(fuelnode)
        push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    else
        _eff = Float64(_eff)
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x[1] / _eff))
    end

    # special case: cycling constraints for nuclear
    _reload_on = false
    if !uc && (!isnothing(reload_duration) || !isnothing(reloadmask) || !isnothing(reload_fraction_per_year))
        @warn "Because uc=false for nuclear component, reloading is not modeled." component=cname tech=tech
    end
    if uc
        _reload_fraction = isnothing(reload_fraction_per_year) ? gettechparam(s, tech, "reload_fraction_per_year", "dispatchable") : reload_fraction_per_year
        @argcheck _reload_fraction isa Number "reload_fraction_per_year must be Number."
        @argcheck _reload_fraction >= 0 "reload_fraction_per_year must be >= 0."
        if _reload_fraction > 0
            _reload_duration = isnothing(reload_duration) ? gettechparam(s, tech, "reload_duration", "dispatchable") : reload_duration
            @argcheck _reload_duration isa Number "reload_duration must be Number."
            @argcheck _reload_duration >= 0 "reload_duration must be >= 0."
            _reload_on = (_reload_fraction > 0) && (_reload_duration > 0)
            if _reload_on
                @argcheck !isnothing(reloadmask) "reloadmask must be provided when reloading is enabled."
                _reload_mask_raw = reloadmask
                @argcheck _reload_mask_raw isa Number "reloadmask must be Number."
                @argcheck _reload_mask_raw > 0 "reloadmask must be > 0 when reloading is enabled."
                @argcheck isinteger(_reload_mask_raw) "reloadmask must be integer-valued."
                _reload_mask = Int(_reload_mask_raw)
            end
        end
        _noload = isnothing(no_load_cost) ? gettechparam(s, tech, "no_load_cost", "dispatchable") : no_load_cost
        _startup = isnothing(startup_cost) ? gettechparam(s, tech, "startup_cost", "dispatchable") : startup_cost
        @argcheck _noload isa Number "no_load_cost must be Number."
        @argcheck _startup isa Number "startup_cost must be Number."
        if isnothing(ini)
            _min_power = isnothing(min_power) ? gettechparam(s, tech, "min_power", "dispatchable") : min_power
            _min_uptime = isnothing(min_uptime) ? gettechparam(s, tech, "min_uptime", "dispatchable") : min_uptime
            _min_downtime = isnothing(min_downtime) ? gettechparam(s, tech, "min_downtime", "dispatchable") : min_downtime
            _startup_dur = isnothing(startup_duration) ? gettechparam(s, tech, "startup_duration", "dispatchable") : startup_duration
            _shutdown_dur = isnothing(shutdown_duration) ? gettechparam(s, tech, "shutdown_duration", "dispatchable") : shutdown_duration
            @argcheck _min_power isa Number "min_power must be Number."
            @argcheck _min_uptime isa Number "min_uptime must be Number."
            @argcheck _min_downtime isa Number "min_downtime must be Number."
            @argcheck _startup_dur isa Number "startup_duration must be Number."
            @argcheck _shutdown_dur isa Number "shutdown_duration must be Number."
            if _reload_on
                push!(vb, Nosy.UnitCommitment("output", 
                    _min_power, 
                    uptime=_min_uptime, 
                    downtime=[_min_downtime, _reload_duration], 
                    startup=_startup_dur, 
                    shutdown=_shutdown_dur,
                    startupmask=startupmask,
                    shutdownmask=shutdownmask,
                    integer=integeruc)
                )
            else
                push!(vb, Nosy.UnitCommitment("output", 
                    _min_power, 
                    uptime=_min_uptime, 
                    downtime=_min_downtime,
                    startup=_startup_dur, 
                    shutdown=_shutdown_dur,
                    startupmask=startupmask,
                    shutdownmask=shutdownmask,
                    integer=integeruc)
                )
            end
            push!(vb, NoLoadCost(:noload, "output", _noload))
            push!(vb, StartupCost(:startup, "output", _startup))
        elseif Nosy.hascomponent(ini, cname * " " * elec.name)
            push!(vb, NoLoadCost(:noload, "output", _noload))
            push!(vb, StartupCost(:startup, "output", _startup))
            push!(vb, UnitCommitment(first(Nosy.getbehaviors(ini.components[cname * " " * elec.name], Nosy.FleetUnitCommitmentBehavior))))
        else
            uc = false # not considering uc for the rest of the method
        end
    end
    
    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    if uc
        _ucb = first(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        if tech in ("Nuclear", "Nuclear flexible",)
            # reduce capabilities of short shutdown
            if _reload_on
                for h in 1:8760
                    # reduce possibilities for reloading type shutdown
                    if !iszero((h-1)%(12))
                        # reduce possibilities for startup
                        e = _ucb.startup[h]
                        if (e isa GenericAffExpr) && !iszero(e)
                            v = first(e.terms)[1]
                            fix(v, 0., force=true)
                        end                

                        # reduce possibilities for normal shutdown
                        e = _ucb.shutdownselector[1][h]
                        if (e isa GenericAffExpr) && !iszero(e)
                            v = first(e.terms)[1]
                            fix(v, 0., force=true)
                        end
                    end
                end
            end

            # reloading of nuclear fuel
            if _reload_on
                sum_reload = AffExpr(0.)
                for h in 1:8760
                    # reduce possibilities for reloading type shutdown
                    if !iszero((h-1)%_reload_mask)
                        e = _ucb.shutdownselector[2][h]
                        if (e isa GenericAffExpr) && !iszero(e)
                            v = first(e.terms)[1]
                            fix(v, 0., force=true)
                        end
                    else
                        add_to_expression!(sum_reload, _ucb.shutdownselector[2][h])
                    end
                end
                @constraint(s.sim.model, sum_reload >= _reload_fraction * nbunits(c))
            end
        elseif tech == "SMR"
            # reloading of nuclear fuel
            if _reload_on
                sum_reload = AffExpr(0.)
                for h in 1:8760
                    # reduce possibilities for reloading type shutdown
                    if !iszero((h-1)%_reload_mask)
                        e = _ucb.shutdownselector[2][h]
                        if (e isa GenericAffExpr) && !iszero(e)
                            v = first(e.terms)[1]
                            fix(v, 0., force=true)
                        end
                    else
                        add_to_expression!(sum_reload, _ucb.shutdownselector[2][h])
                    end
                end
                @constraint(s.sim.model, sum_reload >= _reload_fraction * nbunits(c))
            end
        end
    end
    for t in ("generation", "dispatchable")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    if !isnothing(fuelnode)
        connect!(s, c, fuelnode)
    end

    return c
end

"""
    makesmr(cname::String, tech::String, elec::Node, heat::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, integercap=false, ini=nothing, warmstart=nothing,
        co2price=co2_price(s),
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing,
        waste_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing, unit_size::Union{Nothing,Number}=nothing,
    )

Build, connect and return an SMR component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `dispatchable` tech data sheet.
  * elec: Electricity output node.
  * heat: Auxiliary heat accounting node. SMR adds a linked heat flow at 1:1 with electric output.
  * co2: CO2 node connected when `co2_emission != 0`.
  * s: snapshot to register the component in.

  * cap: Fixed output capacity. If `nothing`, optimize capacity with optional bounds.
  * mincap: Capacity bounds used when `cap === nothing`.
  * maxcap: Capacity bounds used when `cap === nothing`.
  * integercap: Integer expansion flag for capacity decision.
  * ini: Optional initial snapshot for inherited capacity.
  * warmstart: Warm start value passed to variable capacity behavior.

  * co2price: CO2 cost coefficient used for linked CO2 flow cost.

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * lifetime: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms (`> 0`, integer-valued). If `nothing`, values are read from Excel.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. If `nothing`, read from Excel.
  * connection_cost: Ratio applied on annualized investment as connection cost.
  * om_var_cost: Variable O&M cost on output energy flow.
  * fuel_cost: Fuel variable cost on output energy flow.
  * waste_cost: Nuclear waste variable cost on output energy flow.
  * co2_emission: Emission factor linking output energy to CO2 output flow.
  * unit_size: Unit block size for discrete capacity representation.
"""
function makesmr(cname::String, tech::String, elec::Node, heat::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap=nothing, mincap=nothing, maxcap=nothing, integercap=false, ini::Union{Nothing,Snapshot}=nothing, warmstart=nothing,

    # external prices
    co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing,
    waste_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing,
    unit_size::Union{Nothing,Number}=nothing,
)
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "dispatchable") : connection_cost
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
    _waste = isnothing(waste_cost) ? gettechparam(s, tech, "waste_cost", "dispatchable") : waste_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    _usize_raw = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, fuel_cost=_fuel, waste_cost=_waste, decommissioning=_decom,
        co2_emission=_co2_em, unit_size=_usize_raw,
    )
    validate_component_input(inputs)

    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "dispatchable") : decommissioning_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    push!(vb, VariableCost(:waste, "output", energy, _waste))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    
    push!(vb, LinkedJointFlow("heat", heat.carrier, :output, "output", x->x[1] * 1)) # actually not heat, but modeled as a 1:1 ratio to keep track of SMR and align it with HTE 
    
    if iszero(_usize_raw)
        _usize = nothing
    else
        @argcheck _usize_raw > 0 "unit_size must be > 0 when non-zero."
        _usize = _usize_raw
    end
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap, unitsize=_usize))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, unitsize=_usize, integer=integercap, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap, warmstart=warmstart))
        else
            push!(vb, FixedCapacity("output", energy, capacity(ini, cname * " " * elec.name), unitsize=_usize))
        end
    end

    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    for t in ("generation", "dispatchable")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    connect!(s, c, heat)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    


    return c
end

"""
    makenuclearprofile(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, weatheryear=2019, co2price=co2_price(s),
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing,
        construction_profile=nothing, decommissioning_profile=nothing, om_var_cost::Union{Nothing,Number}=nothing,
        fuel_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing,
    )

Build, connect and return a profile based nuclear generation component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `dispatchable` tech data sheet.
  * elec: electricity node to connect the component to.
  * co2: CO2 node connected when `co2_emission` is non zero.
  * s: snapshot to register the component in.

  * cap: Fixed output capacity. If `nothing`, output capacity is optimized.
  * weatheryear: Year suffix used to select profile series `profiles_<year>`.

  * co2price: CO2 cost coefficient applied to emitted CO2 flow.

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms (`> 0`, integer-valued). Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. Excel defaults are used when values are `nothing`.
  * om_var_cost: Variable O&M coefficient on output energy flow.
  * fuel_cost: Fuel variable cost coefficient on output energy flow.
  * co2_emission: Emission factor linking output energy to CO2 output flow.
"""
function makenuclearprofile(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, weatheryear=2019,

    co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    om_var_cost::Union{Nothing,Number}=nothing, fuel_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing,
)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech * "_" * elec.name, "profiles_" * string(weatheryear)))
    vb = []
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, om_fixed_cost=_fom, om_var_cost=_vom,
        fuel_cost=_fuel, decommissioning=_decom, co2_emission=_co2_em,
    )
    validate_component_input(inputs)

    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "dispatchable") : decommissioning_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    elseif isnothing(cap)
        push!(vb, VariableCapacity("output", energy))
    end
    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    for t in ("generation", "dispatchable", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end

"""
    makereservoirprofile(cname::String, zone::String, elec::Node, s::Snapshot;
        cap=nothing, tech::String="Hydro reservoir",
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        om_var_cost::Union{Nothing,Number}=nothing, decommissioning::Union{Nothing,Number}=nothing,
        lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a profile-based hydro reservoir generation component.

Arguments:
  * cname: component name prefix.
  * zone: time-series zone used to read `fixed_reservoir_output`.
  * elec: electricity node to connect the component to.
  * s: snapshot to register the component in.
  * cap: Installed output capacity used to normalize the profile (`cap > 0` required; `nothing` is rejected).
  * tech: technology row name in the `storage` tech data sheet.
  * overnight_cost: optional CAPEX override for annualization. If `nothing`, read from Excel.
  * om_fixed_cost: optional fixed O&M override. If `nothing`, read from Excel.
  * om_var_cost: optional variable O&M override. If `nothing`, read from Excel.
  * decommissioning: optional decommissioning ratio override. If `nothing`, read from Excel.
  * lifetime: optional lifetime override (`> 0`, integer-valued). If `nothing`, read from Excel.
  * construction_profile: optional construction profile override used in annualization.
  * decommissioning_profile: optional decommissioning profile override passed to `decom_cost(...)`.
"""
function makereservoirprofile(cname::String, zone::String, elec::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, tech::String="Hydro reservoir",

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    om_var_cost::Union{Nothing,Number}=nothing, decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing,
    construction_profile=nothing, decommissioning_profile=nothing,
)
    if cap isa Number
        @argcheck cap > 0 "makereservoirprofile requires `cap > 0` for profile normalization."
        m = ProfileSource(elec.carrier, gettimeseries(s, zone, "fixed_reservoir_output") / cap)
    elseif isnothing(cap)
        throw(ArgumentError("makereservoirprofile requires numeric `cap` (cannot be `nothing`) because profile is normalized by cap."))
    else
        throw(ArgumentError("makereservoirprofile `cap` must be a Number."))
    end
    vb = []
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    end
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "storage") : lifetime
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "storage") : om_fixed_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "storage") : decommissioning
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "storage") : om_var_cost
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, om_fixed_cost=_fom,
        decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "storage") : decommissioning_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    for t in ("generation", "dispatchable", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end

"""
    makeintermittentsource(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing, weatheryear=2019,
        co2price=co2_price(s),
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing,
        fuel_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing,
    )

Build, connect and return an intermittent source component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `intermittent` tech data sheet.
  * elec: electricity node to connect the component to.
  * co2: CO2 node connected when `co2_emission` is non zero.
  * s: snapshot to register the component in.

  * cap: Fixed output capacity. If `nothing`, capacity is optimized.
  * mincap: Bounds for optimized capacity when `cap === nothing`.
  * maxcap: Bounds for optimized capacity when `cap === nothing`.
  * ini: Optional initial snapshot used to inherit fixed capacity.
  * weatheryear: Year suffix used to select profile series `profiles_<year>`.

  * co2price: CO2 cost coefficient applied to emitted CO2 flow.

  * overnight_cost: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms (`> 0`, integer-valued). Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. Excel defaults are used when values are `nothing`.
  * connection_cost: Ratio applied to annualized investment as connection fixed cost.
  * om_var_cost: Variable O&M coefficient on output energy flow.
  * fuel_cost: Fuel variable cost coefficient on output energy flow.
  * co2_emission: Emission factor linking output energy to CO2 output flow.
"""
function makeintermittentsource(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, weatheryear=2019,

    co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing,
    fuel_cost::Union{Nothing,Number}=nothing, co2_emission::Union{Nothing,Number}=nothing,
)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech * "_" * elec.name, "profiles_" * string(weatheryear)))
    vb = []
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "intermittent") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "intermittent") : decommissioning_profile
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "intermittent") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "intermittent") : lifetime
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "intermittent") : connection_cost
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "intermittent") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "intermittent") : om_var_cost
    _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "intermittent") : fuel_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "intermittent") : decommissioning
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "intermittent") : co2_emission
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, fuel_cost=_fuel, decommissioning=_decom, co2_emission=_co2_em,
    )
    validate_component_input(inputs)

    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _inv = eac(_oc, discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, lb=isnothing(mincap) ? 0 : mincap, ub=isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("output", energy, capacity(ini, cname * " " * elec.name)))
        end
    end
    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    for t in ("generation", "intermittent", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end

"""
    makehydroror(cname::String, zone::String, elec::Node, s::Snapshot;
        cap=nothing, tech::String="Hydro ror", weatheryear=2019, intake_mult=1.,
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing, om_var_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a run of river hydro component.

Arguments:
  * cname: component name prefix.
  * zone: Time series zone used to read hydro inflow profile.
  * elec: electricity node to connect the component to.
  * s: snapshot to register the component in.

  * cap: Installed output capacity used to normalize inflow profile. `makehydroror` requires a numeric positive `cap`; `nothing` is rejected.
  * tech: technology row name in the `intermittent` tech data sheet.
  * weatheryear: Year suffix used to select inflow series `hydro_ror_<year>`.

  * intake_mult: Multiplier applied to inflow profile before normalization to `cap`.

  * overnight_cost: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * om_var_cost: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: Cost/lifetime overrides for fixed and variable hydro cost terms (`> 0`, integer-valued). Excel defaults are used when values are `nothing`.
  * construction_profile: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. Excel defaults are used when values are `nothing`.
"""
function makehydroror(cname::String, zone::String, elec::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, tech::String="Hydro ror", weatheryear=2019,

    intake_mult=1.,

    # technical / economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    om_var_cost::Union{Nothing,Number}=nothing, decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing,
    construction_profile=nothing, decommissioning_profile=nothing,
)
    if cap isa Number
        @argcheck cap > 0 "makehydroror requires `cap > 0` for profile normalization."
    elseif isnothing(cap)
        throw(ArgumentError("makehydroror requires numeric `cap` (cannot be `nothing`) because profile is normalized by cap."))
    else
        throw(ArgumentError("makehydroror `cap` must be a Number."))
    end
    _profile = gettimeseries(s, zone, "hydro_ror_$weatheryear")
    m = ProfileSource(elec.carrier, _profile * intake_mult / cap, cutoff=1.)
    vb = []
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    end

    # costs
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "intermittent") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "intermittent") : lifetime
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "intermittent") : om_fixed_cost
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "intermittent") : decommissioning
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "intermittent") : om_var_cost
    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, om_fixed_cost=_fom,
        decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "intermittent") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "intermittent") : decommissioning_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    push!(vb, VariableCost(:vom, "output", energy, _vom))

    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    for t in ("generation", "intermittent", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end
