"""
Generate generation-side components.
"""

using ArgCheck: @argcheck

function makeflathydrogenpurchase(cname::String, n::Node, val::Number, s::Snapshot)
    m = ProfileSource(n.carrier, 1.)
    vb = []
    push!(vb, FixedCapacity("output", energy, val/8760))
    c = Component(cname * " " * n.name, m, vb)
    for t in (:hydrogen, :purchase)
        tag!(c, t)
    end
    connect!(s, c, n)
    return c
end

"""
    makedispatchable(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing, capacitymultiplier=nothing,
        integeruc=false, uc=false, fuelnode=nothing,
        capex_mult=1., fuel_mult=1., co2price=co2_price(s),
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
        connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, no_load_cost=nothing, startup_cost=nothing,
        co2_emission=nothing, efficiency=nothing, unit_size=nothing, min_power=nothing, min_uptime=nothing,
        min_downtime=nothing, startup_duration=nothing, shutdown_duration=nothing,
    )

Build, connect and return a dispatchable component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `dispatchable` tech data sheet.
  * elec: Electricity node connected to component output flow.
  * co2: CO2 node connected only when `co2_emission != 0`.
  * s: Target snapshot where the component and behaviors are registered.

  * cap: Fixed output capacity in model power units. If `nothing`, output capacity is a decision variable.
  * mincap: Lower/upper bounds for variable capacity when `cap === nothing`.
  * maxcap: Lower/upper bounds for variable capacity when `cap === nothing`.
  * ini: Optional initial snapshot. If provided, capacity/UC state is inherited from the matching component.
  * capacitymultiplier: Time varying multiplier applied to output capacity (capacity basis, not energy basis).

  * integeruc: If `true`, UC commitment variables are integer (mixed integer UC).
  * uc: Enables UC constraints and UC linked costs (`no_load_cost`, `startup_cost`).
  * fuelnode: If provided, fuel is modeled as an input flow linked by efficiency. If `nothing`, fuel is modeled as a variable cost on output energy (`fuel_cost`).

  * capex_mult: Scenario multiplier for annualized investment related costs.
  * fuel_mult: Scenario multiplier applied to direct fuel cost (only when `fuelnode === nothing`).
  * co2price: CO2 cost coefficient used with emitted CO2 flow.

  * overnight_cost: Overnight CAPEX input used by `eac(...)` (Excel default when `nothing`).
  * om_fixed_cost: Fixed O&M cost on output capacity (`FixedCost(:fom, "output", ...)`; Excel default when `nothing`).
  * decommissioning: Decommissioning cost ratio used in `decom_cost(...)` (Excel default when `nothing`).
  * lifetime: Asset lifetime used by annualization/decommissioning calculations.
  * construction_profile: Construction cost share profile passed to `eac(...)` (Excel default when `nothing`).
  * connection_cost: Connection cost ratio applied on annualized investment.
  * om_var_cost: Variable O&M cost on output energy flow (`VariableCost(:vom, "output", ...)`).
  * fuel_cost: Direct fuel variable cost on output energy. Used only when `fuelnode === nothing`.
  * no_load_cost: UC no load cost applied per committed output state and time step. Used only when `uc=true`.
  * startup_cost: UC startup cost applied to startup events. Used only when `uc=true`.
  * co2_emission: CO2 emission factor linked from output energy to CO2 flow (`output * co2_emission / 1000`).
  * efficiency: Fuel to output conversion efficiency for linked fuel flow. Required when `fuelnode` is provided.
  * unit_size: Unit block size for discrete capacity representation. `0` is treated as no unit size constraint.
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

    # scenario controls
    capex_mult=1., fuel_mult=1., co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, no_load_cost=nothing, startup_cost=nothing,
    co2_emission=nothing, efficiency=nothing, unit_size=nothing, min_power=nothing, min_uptime=nothing,
    min_downtime=nothing, startup_duration=nothing, shutdown_duration=nothing,
)
    for param in ("reload_duration", "reload_fraction_per_year", "reloadmask")
        val = gettechparam_optional(s, tech, param, "dispatchable")
        @argcheck isnothing(val) || iszero(val) " `$param` is only supported by `makenuclear`, not by `makedispatchable`."
    end
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "dispatchable") : connection_cost
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    
    # capacity multiplier
    if !isnothing(capacitymultiplier)
        push!(vb, CapacityMultiplier("output", capacitymultiplier))
    end

    # fuel cost only used is fuel node is nothing
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    _usize_raw = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    @argcheck _usize_raw isa Real "unit_size must be Real."
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
        _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
        push!(vb, VariableCost(:fuel, "output", energy, _fuel * fuel_mult))
    else
        _eff = isnothing(efficiency) ? gettechparam(s, tech, "efficiency", "dispatchable") : efficiency
        @argcheck _eff isa Real "efficiency must be Real."
        @argcheck 0 < _eff <= 1 "efficiency must be in (0, 1]."
        _eff = Float64(_eff)
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x[1] / _eff))
    end

    # special case: cycling constraints for nuclear
    if uc
        if isnothing(ini)
            _min_power = isnothing(min_power) ? gettechparam(s, tech, "min_power", "dispatchable") : min_power
            _min_uptime = isnothing(min_uptime) ? gettechparam(s, tech, "min_uptime", "dispatchable") : min_uptime
            _min_downtime = isnothing(min_downtime) ? gettechparam(s, tech, "min_downtime", "dispatchable") : min_downtime
            _startup_dur = isnothing(startup_duration) ? gettechparam(s, tech, "startup_duration", "dispatchable") : startup_duration
            _shutdown_dur = isnothing(shutdown_duration) ? gettechparam(s, tech, "shutdown_duration", "dispatchable") : shutdown_duration
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
        push!(vb, NoLoadCost(:noload, "output", _noload))
        push!(vb, StartupCost(:startup, "output", _startup))
    end

    # ramping
    # _ru = gettechparam(s, tech, "ramp_up", "dispatchable")
    # if !iszero(_ru) && !isone(_ru)
    #     push!(vb, Ramping("output", :up, _ru, energy))
    # end
    # _rd = gettechparam(s, tech, "ramp_down", "dispatchable")
    # if !iszero(_rd) && !isone(_rd)
    #     push!(vb, Ramping("output", :down, _rd, energy))
    # end

    c = Component(cname * " " * elec.name, m, vb)
    for t in (:generation, :dispatchable)
        tag!(c, t)
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
        reload_duration=nothing, reloadmask=nothing, reload_fraction_per_year=nothing,
        fuelnode=nothing, co2price=co2_price(s),
        capex_mult=1., fuel_mult=1.,
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
        connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, waste_cost=nothing, no_load_cost=nothing,
        startup_cost=nothing, co2_emission=nothing, efficiency=nothing, unit_size=nothing, min_power=nothing,
        min_uptime=nothing, min_downtime=nothing, startup_duration=nothing, shutdown_duration=nothing,
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
  * reloadmask: Interval between allowed reload windows. If `nothing`, read from Excel. When reloading is enabled, value must be strictly positive.
  * reload_fraction_per_year: Minimum yearly reload requirement (fraction per unit per year). If `nothing`, read from Excel. Must be >= 0; reloading constraints are enabled only when this value is > 0.

  * fuelnode: If provided, fuel is represented as linked input flow using `efficiency`. If `nothing`, `fuel_cost` is applied as output variable cost.
  * co2price: CO2 price coefficient for emitted CO2 flow.

  * capex_mult: Scenario multipliers for investment related costs and direct fuel cost.
  * fuel_mult: Scenario multipliers for investment related costs and direct fuel cost.

  * overnight_cost: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * decommissioning: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * lifetime: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
  * construction_profile: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Excel defaults are used when values are `nothing`.
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
    reload_duration=nothing, reloadmask=nothing, reload_fraction_per_year=nothing,

    # external nodes / prices
    fuelnode=nothing, co2price=co2_price(s),

    # scenario multipliers
    capex_mult=1., fuel_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, waste_cost=nothing, no_load_cost=nothing,
    startup_cost=nothing, co2_emission=nothing, efficiency=nothing, unit_size=nothing, min_power=nothing,
    min_uptime=nothing, min_downtime=nothing, startup_duration=nothing, shutdown_duration=nothing,
)
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "dispatchable") : connection_cost
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    _waste = isnothing(waste_cost) ? gettechparam(s, tech, "waste_cost", "dispatchable") : waste_cost
    push!(vb, VariableCost(:waste, "output", energy, _waste))
    # fuel cost only used is fuel node is nothing
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    _usize_raw = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    @argcheck _usize_raw isa Real "unit_size must be Real."
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
    if isnothing(fuelnode)
        _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
        push!(vb, VariableCost(:fuel, "output", energy, _fuel * fuel_mult))
    else
        _eff = isnothing(efficiency) ? gettechparam(s, tech, "efficiency", "dispatchable") : efficiency
        @argcheck _eff isa Real "efficiency must be Real."
        @argcheck 0 < _eff <= 1 "efficiency must be in (0, 1]."
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
        @argcheck _reload_fraction isa Real "reload_fraction_per_year must be Real."
        @argcheck _reload_fraction >= 0 "reload_fraction_per_year must be >= 0."
        if _reload_fraction > 0
            _reload_duration = isnothing(reload_duration) ? gettechparam(s, tech, "reload_duration", "dispatchable") : reload_duration
            @argcheck _reload_duration isa Real "reload_duration must be Real."
            @argcheck _reload_duration >= 0 "reload_duration must be >= 0."
            _reload_on = (_reload_fraction > 0) && (_reload_duration > 0)
            if _reload_on
                _reload_mask_raw = isnothing(reloadmask) ? gettechparam(s, tech, "reloadmask", "dispatchable") : reloadmask
                @argcheck _reload_mask_raw isa Real "reloadmask must be Real."
                @argcheck _reload_mask_raw > 0 "reloadmask must be > 0 when reloading is enabled."
                @argcheck isinteger(_reload_mask_raw) "reloadmask must be integer-valued."
                _reload_mask = Int(_reload_mask_raw)
            end
        end
        _noload = isnothing(no_load_cost) ? gettechparam(s, tech, "no_load_cost", "dispatchable") : no_load_cost
        _startup = isnothing(startup_cost) ? gettechparam(s, tech, "startup_cost", "dispatchable") : startup_cost
        if isnothing(ini)
            _min_power = isnothing(min_power) ? gettechparam(s, tech, "min_power", "dispatchable") : min_power
            _min_uptime = isnothing(min_uptime) ? gettechparam(s, tech, "min_uptime", "dispatchable") : min_uptime
            _min_downtime = isnothing(min_downtime) ? gettechparam(s, tech, "min_downtime", "dispatchable") : min_downtime
            _startup_dur = isnothing(startup_duration) ? gettechparam(s, tech, "startup_duration", "dispatchable") : startup_duration
            _shutdown_dur = isnothing(shutdown_duration) ? gettechparam(s, tech, "shutdown_duration", "dispatchable") : shutdown_duration
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
    for t in (:generation, :dispatchable)
        tag!(c, t)
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
        capex_mult=1., fuel_mult=1.,
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
        connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, waste_cost=nothing, co2_emission=nothing,
        unit_size=nothing,
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

  * capex_mult: Scenario multiplier on annualized investment related costs.
  * fuel_mult: Scenario multiplier applied to `fuel_cost`.

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * lifetime: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualization and decommissioning terms. If `nothing`, values are read from Excel.
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

    # scenario multipliers
    capex_mult=1.,
    fuel_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, waste_cost=nothing, co2_emission=nothing,
    unit_size=nothing,
)
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "dispatchable") : connection_cost
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
    push!(vb, VariableCost(:fuel, "output", energy, _fuel * fuel_mult))
    _waste = isnothing(waste_cost) ? gettechparam(s, tech, "waste_cost", "dispatchable") : waste_cost
    push!(vb, VariableCost(:waste, "output", energy, _waste))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    
    push!(vb, LinkedJointFlow("heat", heat.carrier, :output, "output", x->x[1] * 1)) # actually not heat, but modeled as a 1:1 ratio to keep track of SMR and align it with HTE 
    
    _usize_raw = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    @argcheck _usize_raw isa Real "unit_size must be Real."
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
    for t in (:generation, :dispatchable)
        tag!(c, t)
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
        cap=nothing, weatheryear=2019, co2price=co2_price(s), capex_mult=1.,
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing,
        construction_profile=nothing, om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing,
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
  * capex_mult: Scenario multiplier applied to annualized investment related costs.

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualized investment and decommissioning terms. Excel defaults are used when values are `nothing`.
  * om_var_cost: Variable O&M coefficient on output energy flow.
  * fuel_cost: Fuel variable cost coefficient on output energy flow.
  * co2_emission: Emission factor linking output energy to CO2 output flow.
"""
function makenuclearprofile(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, weatheryear=2019,

    # scenario controls
    co2price=co2_price(s), capex_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing,
)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech * "_" * elec.name, "profiles_" * string(weatheryear)))
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "dispatchable") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "dispatchable") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "dispatchable") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "dispatchable") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
    push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "dispatchable") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "dispatchable") : co2_emission
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
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    for t in (:generation, :dispatchable, :carbonfree,)
        tag!(c, t)
    end
    return c
end

function makereservoirprofile(cname::String, zone::String, elec::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, tech::String="Hydro reservoir",

    # scenario controls
    capex_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing,
    construction_profile=nothing,
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
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "storage") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "storage") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "storage") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "storage") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    c = Component(cname * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:generation, :dispatchable, :carbonfree,)
        tag!(c, t)
    end
    return c
end

"""
    makeintermittentsource(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing, weatheryear=2019,
        capex_mult=1., co2price=co2_price(s),
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
        connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing,
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

  * capex_mult: Scenario multiplier on annualized investment related costs.
  * co2price: CO2 cost coefficient applied to emitted CO2 flow.

  * overnight_cost: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * connection_cost: Ratio applied to annualized investment as connection fixed cost.
  * om_var_cost: Variable O&M coefficient on output energy flow.
  * fuel_cost: Fuel variable cost coefficient on output energy flow.
  * co2_emission: Emission factor linking output energy to CO2 output flow.
"""
function makeintermittentsource(cname::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, weatheryear=2019,

    # scenario controls
    capex_mult=1., co2price=co2_price(s),

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing,
)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech * "_" * elec.name, "profiles_" * string(weatheryear)))
    vb = []
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "intermittent") : construction_profile
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "intermittent") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "intermittent") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "intermittent") : connection_cost
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "intermittent") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "intermittent") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "intermittent") : fuel_cost
    push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "intermittent") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _co2_em = isnothing(co2_emission) ? gettechparam(s, tech, "co2_emission", "intermittent") : co2_emission
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
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    for t in (:generation, :intermittent, :carbonfree)
        tag!(c, t)
    end
    return c
end

"""
    makehydroror(cname::String, zone::String, elec::Node, s::Snapshot;
        cap=nothing, tech::String="Hydro ror", weatheryear=2019, intake_mult=1., capex_mult=1.,
        overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing,
        decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
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
  * capex_mult: Scenario multiplier on annualized investment related costs.

  * overnight_cost: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * om_var_cost: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
  * construction_profile: Cost/lifetime overrides for fixed and variable hydro cost terms. Excel defaults are used when values are `nothing`.
"""
function makehydroror(cname::String, zone::String, elec::Node, s::Snapshot;
    # capacity / profile
    cap=nothing, tech::String="Hydro ror", weatheryear=2019,

    # scenario controls
    intake_mult=1., capex_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing,
    construction_profile=nothing,
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
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "intermittent") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "intermittent") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "intermittent") : construction_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "intermittent") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "intermittent") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "intermittent") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))

    c = Component(cname * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:generation, :intermittent, :carbonfree)
        tag!(c, t)
    end
    return c
end
