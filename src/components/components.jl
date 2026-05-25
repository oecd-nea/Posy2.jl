"""
Generate components.
"""

using ArgCheck: @argcheck

"""
    makedemand(name::String, tech::String, n::Node, s::Snapshot; coeff=1.0, shift::Int=0)
Build, connect and return a component based on the Demand template.
Arguments:
  * zone: name of time series in the time series file
  * coeff: multiplicative coefficient, applied at every hour (applies to the profile part of the demand, not the flat part)
  * shift: circular shift of demand time series (e.g. to make year start on monday)
"""
function makedemand(name::String, zone::String, n::Node, s::Snapshot; coeff=1.0, shift::Int=0, yearlyconstant::Float64=0., gridlosses=0.)
    if iszero(coeff)
        var = 0.
    else
        var = coeff * gettimeseries(s, zone, "demand") 
        circshift!(var, shift)
    end

    m = Demand(n.carrier, (var .+ yearlyconstant / 8760))
    vb = []
    !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", n.carrier, :input, "input", x->x[1] * gridlosses))
    c = Component(name * " " * n.name, m, vb)
    for t in (:electricity, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)   
    return c
end

function makeEV(name::String, yearly::Float64, offhours1::AbstractVector{<:Int}, offhours2::AbstractVector{<:Int}, minratio::Float64, n::Node, s::Snapshot; gridlosses=0., days_threshold=104)
    @assert all(0 <= h <= 23 for h in offhours1) "offhours1 must be integers between 0 and 23"
    @assert all(0 <= h <= 23 for h in offhours2) "offhours2 must be integers between 0 and 23"

    maxlevel = yearly / ((183 * ((24 - length(offhours1)) + length(offhours1) * minratio)) + 182 * ((24 - length(offhours2)) + length(offhours2) * minratio))
    
    series = vcat(
        repeat([h in offhours1 ? minratio : 1.0 for h in 0:23], days_threshold), # winter
        repeat([h in offhours2 ? minratio : 1.0 for h in 0:23], 182), # summer
        repeat([h in offhours1 ? minratio : 1.0 for h in 0:23], 183 - days_threshold), # winter
    ) * maxlevel

    m = Demand(n.carrier, series)
    vb = []
    !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", n.carrier, :input, "input", x->x[1] * gridlosses))
    c = Component(name * " " * n.name, m, vb)
    for t in (:electricity, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)   
    return c
end

function makeflathydrogendemand(name::String, n::Node, val::Number, s::Snapshot)
    m = Demand(n.carrier, val / 8760)
    vb = []
    c = Component(name * " " * n.name, m, vb)
    for t in (:hydrogen, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)
    return c
end

function makeflexhydrogendemand(name::String, n::Node, val::Number, s::Snapshot)
    m = BasicSink(n.carrier)
    vb = []
    push!(vb, YearlySum("input", val, :equal))
    c = Component(name * " " * n.name, m, vb)
    for t in (:hydrogen, :demand)
        tag!(c, t)
    end
    connect!(s, c, n)
    return c
end

function makeflathydrogenpurchase(name::String, n::Node, val::Number, s::Snapshot)
    m = ProfileSource(n.carrier, 1.)
    vb = []
    push!(vb, FixedCapacity("output", energy, val/8760))
    c = Component(name * " " * n.name, m, vb)
    for t in (:hydrogen, :purchase)
        tag!(c, t)
    end
    connect!(s, c, n)
    return c
end

"""
    makedispatchable(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; integeruc=false, cap, mincap=nothing, maxcap=nothing, uc=false, fuelnode=nothing, capacitymultiplier=nothing, capex_mult=1., fuel_mult=1., ini=nothing, co2price=co2_price(s), overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, no_load_cost=nothing, startup_cost=nothing, co2_emission=nothing, efficiency=nothing, unit_size=nothing, min_power=nothing, min_uptime=nothing, min_downtime=nothing, startup_duration=nothing, shutdown_duration=nothing)
Build, connect and return a dispatchable component.
"""
function makedispatchable(name::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, capacitymultiplier=nothing,

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
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "dispatchable")) : Int(lifetime)
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
    _usize = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    _usize = iszero(_usize) ? nothing : _usize
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
            push!(vb, FixedCapacity("output", energy, capacity(ini, name * " " * elec.name), unitsize=_usize))
        end
    end

    # fuel node management
    if isnothing(fuelnode)
        _fuel = isnothing(fuel_cost) ? gettechparam(s, tech, "fuel_cost", "dispatchable") : fuel_cost
        push!(vb, VariableCost(:fuel, "output", energy, _fuel * fuel_mult))
    else
        _eff = isnothing(efficiency) ? gettechparam(s, tech, "efficiency", "dispatchable") : efficiency
        @assert !ismissing(_eff) "Please define the `efficiency` parameter for $name in technological data file."
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
            push!(vb, UnitCommitment(first(Nosy.getbehaviors(ini.components[name * " " * elec.name], Nosy.FleetUnitCommitmentBehavior))))
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

    c = Component(name * " " * elec.name, m, vb)
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
    makenuclear(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; integercap=false, integeruc=false, cap, mincap=nothing, maxcap=nothing, uc=false, fuelnode=nothing, capex_mult=1., fuel_mult=1., ini=nothing, warmstart=nothing, co2price=co2_price(s), startupmask=nothing, shutdownmask=nothing, overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, waste_cost=nothing, no_load_cost=nothing, startup_cost=nothing, co2_emission=nothing, efficiency=nothing, unit_size=nothing, min_power=nothing, min_uptime=nothing, min_downtime=nothing, startup_duration=nothing, shutdown_duration=nothing, reload_duration_hours=nothing, reload_step_hours=24*7, reload_fraction_per_year=1.0)
Build, connect and return a nuclear reactor component.
"""
function makenuclear(name::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap, mincap=nothing, maxcap=nothing, integercap=false, ini::Union{Nothing,Snapshot}=nothing, warmstart=nothing,

    # unit commitment / operation
    uc=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,

    # reloading controls
    reload_duration_hours=nothing, reload_step_hours=24*7, reload_fraction_per_year=1.0,

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
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "dispatchable")) : Int(lifetime)
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
    _usize = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    _usize = iszero(_usize) ? nothing : _usize
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap, unitsize=_usize))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, unitsize=_usize, integer=integercap, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap, warmstart=warmstart))
        elseif Nosy.hascomponent(ini, name * " " * elec.name)
            push!(vb, FixedCapacity("output", energy, capacity(ini, name * " " * elec.name), unitsize=_usize))
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
        @assert !ismissing(_eff) "Please define the `efficiency` parameter for $name in technological data file."
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x[1] / _eff))
    end

    # special case: cycling constraints for nuclear
    _reload_on = false
    _reload_duration = 0
    if uc
        @assert reload_fraction_per_year >= 0 "reload_fraction_per_year must be >= 0."
        if reload_fraction_per_year > 0
            if isnothing(reload_duration_hours)
                _reload_duration = gettechparam(s, tech, "reload_duration_hours", "dispatchable")
                @assert !ismissing(_reload_duration) "Please define `reload_duration_hours` in tech data (dispatchable sheet) for $tech or pass it as argument."
            else
                _reload_duration = reload_duration_hours
            end
            @assert _reload_duration >= 0 "reload_duration_hours must be >= 0."
            _reload_on = (reload_fraction_per_year > 0) && (_reload_duration > 0)
            if _reload_on
                @assert reload_step_hours > 0 "reload_step_hours must be > 0."
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
        elseif Nosy.hascomponent(ini, name * " " * elec.name)
            push!(vb, NoLoadCost(:noload, "output", _noload))
            push!(vb, StartupCost(:startup, "output", _startup))
            push!(vb, UnitCommitment(first(Nosy.getbehaviors(ini.components[name * " " * elec.name], Nosy.FleetUnitCommitmentBehavior))))
        else
            uc = false # not considering uc for the rest of the method
        end
    end
    
    c = Component(name * " " * elec.name, m, vb)
    if uc
        _ucb = first(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        if tech in ("Nuclear", "Nuclear flexible",)
            # reduce capabilities of short shutdown
            if _reload_on
                for h in 1:8760
                    # reduce possibilities for reloading-type shutdown
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
                    # reduce possibilities for reloading-type shutdown
                    if !iszero((h-1)%reload_step_hours)
                        e = _ucb.shutdownselector[2][h]
                        if (e isa GenericAffExpr) && !iszero(e)
                            v = first(e.terms)[1]
                            fix(v, 0., force=true)
                        end
                    else
                        add_to_expression!(sum_reload, _ucb.shutdownselector[2][h])
                    end
                end
                @constraint(s.sim.model, sum_reload >= reload_fraction_per_year * nbunits(c))
            end
        elseif tech == "SMR"
            # reloading of nuclear fuel
            if _reload_on
                sum_reload = AffExpr(0.)
                for h in 1:8760
                    # reduce possibilities for reloading-type shutdown
                    if !iszero((h-1)%reload_step_hours)
                        e = _ucb.shutdownselector[2][h]
                        if (e isa GenericAffExpr) && !iszero(e)
                            v = first(e.terms)[1]
                            fix(v, 0., force=true)
                        end
                    else
                        add_to_expression!(sum_reload, _ucb.shutdownselector[2][h])
                    end
                end
                @constraint(s.sim.model, sum_reload >= reload_fraction_per_year * nbunits(c))
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
    makesmr(name::String, tech::String, elec::Node, heat::Node, co2::Node, s::Snapshot; integercap=false, cap, mincap=nothing, maxcap=nothing, capex_mult=1., fuel_mult=1., ini=nothing, warmstart=nothing, co2price=co2_price(s), overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, waste_cost=nothing, co2_emission=nothing, unit_size=nothing)
Build, connect and return an SMR component.
"""
function makesmr(name::String, tech::String, elec::Node, heat::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap, mincap=nothing, maxcap=nothing, integercap=false, ini::Union{Nothing,Snapshot}=nothing, warmstart=nothing,

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
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "dispatchable")) : Int(lifetime)
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
    
    _usize = isnothing(unit_size) ? gettechparam(s, tech, "unit_size", "dispatchable") : unit_size
    _usize = iszero(_usize) ? nothing : _usize
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap, unitsize=_usize))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, unitsize=_usize, integer=integercap, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap, warmstart=warmstart))
        else
            push!(vb, FixedCapacity("output", energy, capacity(ini, name * " " * elec.name), unitsize=_usize))
        end
    end

    c = Component(name * " " * elec.name, m, vb)
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
    makenuclearprofile(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; cap, weatheryear=2009, co2price=co2_price(s), capex_mult=1., overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing)
Build, connect and return a dispatchable component.
"""
function makenuclearprofile(name::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / profile
    cap, weatheryear=2009,

    # scenario controls
    co2price=co2_price(s), capex_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing,
)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech * "_" * elec.name, "profiles_" * string(weatheryear)))
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "dispatchable") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "dispatchable")) : Int(lifetime)
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
    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    for t in (:generation, :dispatchable, :carbonfree,)
        tag!(c, t)
    end
    return c
end

function makereservoirprofile(name::String, zone::String, elec::Node, s::Snapshot;
    # capacity / profile
    cap, tech::String="Hydro reservoir",

    # scenario controls
    capex_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing,
    construction_profile=nothing,
)
    if cap isa Number
        @assert cap > 0 "makereservoirprofile requires `cap > 0` for profile normalization."
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
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "storage")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "storage") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "storage") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "storage") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:generation, :dispatchable, :carbonfree,)
        tag!(c, t)
    end
    return c
end

"""
    makeintermittentsource(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; cap, mincap=nothing, maxcap=nothing, capex_mult=1., ini=nothing, weatheryear=2009, co2price=co2_price(s), overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, connection_cost=nothing, om_var_cost=nothing, fuel_cost=nothing, co2_emission=nothing)
Build, connect and return an intermittent source component.
"""
function makeintermittentsource(name::String, tech::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / profile
    cap, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, weatheryear=2009,

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
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "intermittent")) : Int(lifetime)
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
            push!(vb, FixedCapacity("output", energy, capacity(ini, name * " " * elec.name)))
        end
    end
    c = Component(name * " " * elec.name, m, vb)
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
    makehydroror(name::String, zone::String, elec::Node, s::Snapshot; cap, tech::String="Hydro ror", weatheryear=2019, intake_mult=1., capex_mult=1., overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing)
Build, connect and return a run-of-river hydro component.
"""
function makehydroror(name::String, zone::String, elec::Node, s::Snapshot;
    # capacity / profile
    cap, tech::String="Hydro ror", weatheryear=2019,

    # scenario controls
    intake_mult=1., capex_mult=1.,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing,
    construction_profile=nothing,
)
    if cap isa Number
        @assert cap > 0 "makehydroror requires `cap > 0` for profile normalization."
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
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "intermittent")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "intermittent") : construction_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "intermittent") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "intermittent") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "intermittent") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))

    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:generation, :intermittent, :carbonfree)
        tag!(c, t)
    end
    return c
end

"""
    makehydroreservoir(name::String, tech::String, zone::String, elec::Node, cap_discharging, cap_charging, cap_reservoir, inflow, s::Snapshot; renormalize=true, weatheryear=2019, gridlosses=0., simplified=false, intake_mult=1., eff=nothing, capex_mult=1., overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing)
Build, connect and return a hydro reservoir component.
NB: no energy capacity at the moment.
"""
function makehydroreservoir(name::String, tech::String, zone::String, elec::Node, cap_discharging, cap_charging, cap_reservoir, inflow, s::Snapshot;
    # storage operation controls
    renormalize=true, weatheryear=2019, gridlosses=0., simplified=false, intake_mult=1.,

    # scenario controls
    capex_mult=1.,

    # technical overrides
    eff=nothing,

    # technical / economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing,
    construction_profile=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "roundtrip_eff", "storage") : eff
    m = LazyStorage(elec.carrier, eff=Dict("natural" => 1., "output" => 1., "input" => _eff, "grid losses" => 0.), simplified=simplified)
    vb = []
    # joint flows for input and output
    push!(vb, FreeJointFlow("output", elec.carrier, :output))

    # costs
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "storage")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _inv = eac(_oc , discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "storage") : om_fixed_cost
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "storage") : decommissioning
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "storage") : om_var_cost
    push!(vb, VariableCost(:vom, "output", energy, _vom))

    if isnothing(inflow)
        # no renormalization via inflow
        _profile = gettimeseries(s, zone, "reservoir_inflow_$weatheryear") * intake_mult
        push!(vb, FixedJointFlow("natural", elec.carrier, :input, _profile, mustconnect=false))
    elseif iszero(inflow)
        nothing # no inflow
    else
        # intake profile
        _profile = gettimeseries(s, zone, "reservoir_inflow_$weatheryear")
        if renormalize 
            _profile = _profile / sum(_profile) * intake_mult
        end   
        push!(vb, FixedJointFlow("natural", elec.carrier, :input, _profile * inflow, mustconnect=false))
    end
    
    if cap_discharging isa Number
        push!(vb, FixedCapacity("output", energy, cap_discharging))
    elseif isnothing(cap_discharging)
        push!(vb, VariableCapacity("output", energy))
    else
        throw(error("cap_discharging is not a number or nothing"))
    end
    if cap_charging isa Number 
        if iszero(cap_charging)
            # charging capacity is not added
            nothing
        else
            push!(vb, FreeJointFlow("input", elec.carrier, :input))
            push!(vb, FixedCapacity("input", energy, cap_charging))
            !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * gridlosses))
        end
    elseif isnothing(cap_charging)
        push!(vb, VariableCapacity("input", energy))
        !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * gridlosses))
    else
        throw(error("cap_charging is not a number or nothing"))
    end
    
    if cap_reservoir isa Number
        push!(vb, FixedCapacity("level", energy, cap_reservoir))
    else
        nothing
        # throw(error("cap_reservoir is not a number"))
    end

    c = Component(name * " " * elec.name, m, vb)
    
    # exogenously force production
    # _output = balance(c, :output, energy, collapse=false).data
    # _profile = gettimeseries(s, zone, "fixed_reservoir_output")
    # @constraint(sim(c).model, _output .== _profile)

    connect!(s, c, elec)
    for t in (:generation, :storage, :carbonfree,)
        tag!(c, t)
    end
    return c
end

"""
    makebatteries(name::String, tech::String, elec::Node, s::Snapshot; capin, eff=nothing, duration=nothing, mincap=nothing, maxcap=nothing, gridlosses=0., capex_mult=1, simplified=false, ini=nothing, overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, connection_cost=nothing, om_var_cost=nothing)
Build, connect and return a battery storage component.
"""
function makebatteries(name::String, tech::String, elec::Node, s::Snapshot;
    # capacity / expansion
    capin, mincap=nothing, maxcap=nothing, simplified::Bool=false, ini::Union{Nothing,Snapshot}=nothing,

    # scenario controls
    gridlosses=0., capex_mult=1,

    # technical overrides
    eff=nothing, duration=nothing,

    # economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    connection_cost=nothing, om_var_cost=nothing,
)
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "storage")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    _eff = isnothing(eff) ? gettechparam(s, tech, "roundtrip_eff", "storage") : eff
    m = BasicStorage(elec.carrier, eff_i=_eff, simplified=simplified)
    vb = []
    
    _dur = isnothing(duration) ? gettechparam(s, tech, "duration", "storage") : duration
    push!(vb, Duration(_dur))
    if capin isa Number
        push!(vb, FixedCapacity("input", energy, capin))
    else
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, name * " " * elec.name)))
        end
    end
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    _conn = isnothing(connection_cost) ? gettechparam(s, tech, "connection_cost", "storage") : connection_cost
    push!(vb, FixedCost(:connection, "input", energy, _inv * _conn))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "storage") : om_fixed_cost
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "storage") : decommissioning
    push!(vb, FixedCost(:decommissioning, "input", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "storage") : om_var_cost
    push!(vb, VariableCost(:vom, "input", energy, _vom))

    if !iszero(gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * gridlosses))
    end

    c = Component(name * " " * elec.name, m, vb)

    for t in (:electricity, :storage, :generation)
        tag!(c, t)
    end
    connect!(s, c, elec)

    return c
end

"""
    makecurtailment(name::String, elec::Node, cost::Number, s::Snapshot)
Build, connect and return a curtailment component.
"""
function makecurtailment(name::String, elec::Node, cost::Number, s::Snapshot)
    @argcheck elec.rule != :curtailed "Curtailment component is not compatible with curtailed node. Use :default node rule instead"
    m = BasicSink(elec.carrier)
    vb = []
    push!(vb, VariableCost(:curtailment, "input", energy, cost))
    push!(vb, FixedCapacity("input", energy, 10000.)) # just for bounding variable
    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:curtailment,)
        tag!(c, t)
    end
    return c
end

"""
    makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot; dir::Bool=false, transactioncost::Number=1.)
Build, connect and return an interconnection component based on a price time series.
If `dir` is true, apply a one-way constraint at every timestep.
"""
function makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=true,

    # economic controls
    transactioncost::Number=1.,
)
    vb = []

    # imports
    m = DispatchableSource(elec.carrier)
    push!(vb, FixedCapacity("output", energy, mcap))
    push!(vb, Nosy.CapacityMultiplier("output", gettimeseries(s, zone * ">" * elec.name, "transfer_capacities")))
    push!(vb, VariableCost(:imports, "output", energy, Float64.(gettimeseries(s, zone, "spot_price", digits=2))))
    push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))

    # exports
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, FixedCapacity("input", energy, xcap))
    push!(vb, Nosy.CapacityMultiplier("input", gettimeseries(s, elec.name * ">" * zone, "transfer_capacities")))
    push!(vb, VariableCost(:exports, "input", energy, -1 * Float64.(gettimeseries(s, zone, "spot_price", digits=2))))
    push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))

    c = Component("IC_" * zone * "_" * elec.name, m, vb)

    # make the IC flow go in one direction only
    if dir
        bin = balance(c, :input, energy, collapse=false, aggregate=true)
        bout = balance(c, :output, energy, collapse=false, aggregate=true)
        for step in eachindex(bin)
            @constraint(Nosy.sim(s).model, [bin[step], bout[step]] in SOS1())
        end
    end
    for t in (:interconnection, :priceinterconnection)
        tag!(c, t)
    end
    if foreign
        tag!(c, :foreign)
    end
    connect!(s, c, elec)

    return c
end

"""
    makenodeinterco(name::String, a::Node, b::Node, mcap::Number, xcap::Number, s::Snapshot)
Build, connect and return an interconnection component linking two nodes.
If `dir` is true, apply a one-way constraint at every timestep.
"""
function makenodeinterco(name::String, a::Node, b::Node, atob::Number, btoa::Number, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=false, dc::Bool=false,

    # economic / physical controls
    transactioncost=1., lossfactor=0.,
)
    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1. - lossfactor)
    
    if !isinf(atob)
        push!(vb, FixedCapacity("input", energy, atob))
        push!(vb, Nosy.CapacityMultiplier("input", gettimeseries(s, a.name * ">" * b.name, "transfer_capacities", digits=2)))
        push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))
    end

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - lossfactor)))
    if !isinf(btoa)
        push!(vb, FixedCapacity("input2", energy, btoa))
        push!(vb, Nosy.CapacityMultiplier("input2", gettimeseries(s, b.name * ">" * a.name, "transfer_capacities", digits=2)))
        push!(vb, VariableCost(:transaction, "input2", energy, Float64(transactioncost)))
    end

    # grid losses balance
    # NB when counting grid losses from interconnectors, make sure to not double-count losses as interconnectors belong to multiple nodes
    push!(vb, LinkedJointFlow("grid losses ic", b.carrier, :output, ("input", "input2"), x->(x[1]+x[2])*lossfactor, mustconnect=false))

    c = Component(string(name, "_", a.name, "_", b.name), m, vb)

    # make the IC flow go in one direction only
    if dir
        bin = balance(c, :input, energy, collapse=false, aggregate=true)
        bout = balance(c, :output, energy, collapse=false, aggregate=true)
        for step in eachindex(bin)
            @constraint(Nosy.sim(s).model, [bin[step], bout[step]] in SOS1())
        end
    end
    
    for t in (:interconnection, :nodeinterconnection)
        tag!(c, t)
    end
    foreign && tag!(c, :foreign) # IC between self and other country
    dc ? tag!(c, :DC) : tag!(c, :AC) # AC or DC

    connect!(s, c, a)
    connect!(s, c, b)

    return c
end


"""
    makeelectrolyser(name::String, tech::String, elec::Node, h2::Node, s::Snapshot; cap, eff=nothing, mincap=nothing, maxcap=nothing, gridlosses=0., capex_mult=1., ini=nothing, overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, om_var_cost=nothing)
Build, connect and return an electrolyser component.
"""
function makeelectrolyser(name::String, tech::String, elec::Node, h2::Node, s::Snapshot;
    # capacity / expansion
    cap, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing,

    # scenario controls
    gridlosses=0., capex_mult=1.,

    # technical overrides
    eff=nothing,

    # economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    om_var_cost=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "efficiency", "electrolysis") : eff
    m = BasicConverter(elec.carrier, h2.carrier, ratio=_eff)
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "electrolysis") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "electrolysis")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "electrolysis") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "electrolysis") : decommissioning
    push!(vb, FixedCost(:decommissioning, "input", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "electrolysis") : om_fixed_cost
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "electrolysis") : om_var_cost
    push!(vb, VariableCost(:vom, "input", energy, _vom))
    if cap isa Number
        push!(vb, FixedCapacity("input", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, name * " " * elec.name)))
        end
    end
    if !iszero(gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * gridlosses))
    end

    c = Component(name * " " * elec.name, m, vb)
    for t in (:demand, :electrolysis, :hydrogen)
        tag!(c, t)
    end
    connect!(s, c, elec)
    connect!(s, c, h2)
    return c
end

"""
    makeHTelectrolyser(name::String, tech::String, elec::Node, heat::Node, h2::Node, s::Snapshot; cap, eff=nothing, mincap=nothing, maxcap=nothing, gridlosses=0., capex_mult=1., ini=nothing, overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing, om_var_cost=nothing)
Build, connect and return an HT electrolyser component.
"""
function makeHTelectrolyser(name::String, tech::String, elec::Node, heat::Node, h2::Node, s::Snapshot;
    # capacity / expansion
    cap, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing,

    # scenario controls
    gridlosses=0., capex_mult=1.,

    # technical overrides
    eff=nothing,

    # economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    om_var_cost=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "efficiency", "electrolysis") : eff
    m = BasicConverter(elec.carrier, h2.carrier, ratio=_eff)
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "electrolysis") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "electrolysis")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "electrolysis") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "electrolysis") : decommissioning
    push!(vb, FixedCost(:decommissioning, "input", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "electrolysis") : om_fixed_cost
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "electrolysis") : om_var_cost
    push!(vb, VariableCost(:vom, "input", energy, _vom))
    if cap isa Number
        push!(vb, FixedCapacity("input", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, name * " " * elec.name)))
        end
    end

    # heat from SMR
    push!(vb, LinkedJointFlow("heat", heat.carrier, :input, "input", x->x[1]))

    if !iszero(gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * gridlosses))
    end

    c = Component(name * " " * elec.name, m, vb)
    for t in (:electrolysis, :hydrogen)
        tag!(c, t)
    end
    connect!(s, c, elec)
    connect!(s, c, heat)
    connect!(s, c, h2)
    return c
end

"""
    makehydrogenstorage(name::String, tech::String, h2::Node, s::Snapshot; cap, eff=nothing, mincap=nothing, maxcap=nothing, capex_mult=1., ini=nothing, overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing)
Build, connect and return a hydrogen storage component.
"""
function makehydrogenstorage(name::String, tech::String, h2::Node, s::Snapshot;
    # capacity / expansion
    cap, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing,

    # scenario controls
    capex_mult=1.,

    # technical overrides
    eff=nothing,

    # economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "roundtrip_eff", "storage") : eff
    m = BasicStorage(h2.carrier, eff_i=_eff, simplified=true) # always simplified for this medium/long-term storage archetype
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt = isnothing(lifetime) ? Int(gettechparam(s, tech, "lifetime", "storage")) : Int(lifetime)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    push!(vb, FixedCost(:investment, "level", energy, _inv))
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "storage") : om_fixed_cost
    push!(vb, FixedCost(:fom, "level", energy, _fom * 1000.))
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "storage") : decommissioning
    push!(vb, FixedCost(:decommissioning, "level", energy, decom_cost(_oc, _decom, _lt, discountrate(s)) * capex_mult))

    if cap isa Number
        push!(vb, FixedCapacity("level", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("level", energy, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        elseif Nosy.hascomponent(ini, name * " " * h2.name)
            push!(vb, FixedCapacity("level", energy, capacity(ini, name * " " * h2.name)))
        else
            push!(vb, FixedCapacity("level", energy, 0.))
        end
    end
    # push!(vb, Duration(4)) # TYNDP methodology 9.6.4: fill in 4 hours # removed for large storage (no meaning, no impact except negative on performance)
    c = Component(name * " " * h2.name, m, vb)
    for t in (:hydrogen, :storage)
        tag!(c, t)
    end
    connect!(s, c, h2)
    return c
end

"""
    makedemandresponse(name::String, elec::Node, capa::Union{Nothing,Number}, cost::Number, s::Snapshot; type::Symbol=:volDR)
Build, connect and return a demand response component.
"""
function makedemandresponse(name::String, elec::Node, capa::Union{Nothing,Number}, cost::Number, s::Snapshot; type::Symbol=:volDR)
    m = DispatchableSource(elec.carrier)
    vb = []
    if !isnothing(capa)
        push!(vb, FixedCapacity("output", energy, capa))
    end
    push!(vb, VariableCost(type, "output", energy, cost * (1-elec.losses))) # do not include demand response in losses

    c = Component(name * " " * elec.name, m, vb)
    for t in (:virtual, :demandresponse)
        tag!(c, t)
    end
    connect!(s, c, elec)
    return c
end