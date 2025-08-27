"""
Generate components.
"""

using ArgCheck: @argcheck

"""
    makedemand(name::String, tech::String, n::Node, s::Snapshot; coeff=1.0, shift::Int=0)
Build, connect and return a component based on the Demand template.
Arguments:
  * tech: name of time series in the time series file
  * coeff: multiplicative coefficient, applied at every hour (applies to the profile part of the demand, not the flat part)
  * shift: circular shift of demand time series (e.g. to make year start on monday)
"""
function makedemand(name::String, tech::String, n::Node, s::Snapshot; coeff=1.0, shift::Int=0, yearlyconstant::Float64=0., gridlosses=0.)
    if iszero(coeff)
        var = 0.
    else
        var = coeff * gettimeseries(s, tech, "demand") 
        circshift!(var, shift)
    end

    m = Demand(n.carrier, (var .+ yearlyconstant / 8760))
    vb = []
    !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", n.carrier, :input, "input", x->x * gridlosses))
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
        repeat([h in offhours1 ? 0.3 : 1.0 for h in 0:23], days_threshold), # winter
        repeat([h in offhours2 ? 0.3 : 1.0 for h in 0:23], 182), # summer
        repeat([h in offhours1 ? 0.3 : 1.0 for h in 0:23], 183 - days_threshold), # winter
    ) * maxlevel

    m = Demand(n.carrier, series)
    vb = []
    !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", n.carrier, :input, "input", x->x * gridlosses))
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
    makedispatchable(name::String, tech::String, elec::Node, co2::Node, cap, s::Snapshot; integer=false)
Build, connect and return a dispatchable component.
"""
function makedispatchable(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; integer=false, cap=nothing, mincap=nothing, maxcap=nothing, uc=false, fuelnode=nothing, ini::Union{Nothing,Snapshot}=nothing, co2price=s.sim.options["CO2 price"])
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = gettechparam(s, tech, "overnight_cost", "dispatchable") * 1000.
    _lt = Int(gettechparam(s, tech, "lifetime", "dispatchable"))
    _cp = gettechparam(s, tech, "construction_profile", "dispatchable")
    push!(vb, FixedCost(:investment, "output", energy, eac(_oc , s.options["discountrate"], _lt, _cp)))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, tech, "om_fixed_cost", "dispatchable") * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, gettechparam(s, tech, "om_var_cost", "dispatchable")))
    # fuel cost only used is fuel node is nothing
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, gettechparam(s, tech, "decommissioning", "dispatchable"), _lt, s.options["discountrate"])))
    if !iszero(gettechparam(s, tech, "co2_emission", "dispatchable"))
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x * gettechparam(s, tech, "co2_emission", "dispatchable") / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    _usize = iszero(gettechparam(s, tech, "unit_size", "dispatchable")) ? nothing : gettechparam(s, tech, "unit_size", "dispatchable")
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap, unitsize=_usize))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("output", energy, unitsize=_usize, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("output", energy, capacity(ini, name * " " * elec.name), unitsize=_usize))
        end
    end

    # fuel node management
    if isnothing(fuelnode)
        push!(vb, VariableCost(:fuel, "output", energy, gettechparam(s, tech, "fuel_cost", "dispatchable")))
    else
        @assert !ismissing(gettechparam(s, tech, "efficiency", "dispatchable")) "Please define the `efficiency` parameter for $name in technological data file."
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x / gettechparam(s, tech, "efficiency", "dispatchable")))
    end

    # special case: cycling constraints for nuclear
    if uc
        if isnothing(ini)
            push!(vb, UnitCommitment("output", 
                gettechparam(s, tech, "min_power", "dispatchable"), 
                uptime=gettechparam(s, tech, "min_uptime", "dispatchable"), 
                downtime=gettechparam(s, tech, "min_downtime", "dispatchable"), 
                startup=gettechparam(s, tech, "startup_duration", "dispatchable"), 
                shutdown=gettechparam(s, tech, "shutdown_duration", "dispatchable"), 
                integer=integer)
            )
        else
            push!(vb, UnitCommitment(first(Nosy.getbehaviors(ini.components[name * " " * elec.name], Nosy.FleetUnitCommitmentBehavior))))
        end
        push!(vb, NoLoadCost(:noload, "output", gettechparam(s, tech, "no_load_cost", "dispatchable")))
        push!(vb, StartupCost(:startup, "output", gettechparam(s, tech, "startup_cost", "dispatchable")))
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
    if !iszero(gettechparam(s, tech, "co2_emission", "dispatchable"))
        connect!(s, c, co2)
    end
    if !isnothing(fuelnode)
        connect!(s, c, fuelnode)
    end
    return c
end

"""
    makenuclear(name::String, tech::String, elec::Node, co2::Node, cap, s::Snapshot; integer=false)
Build, connect and return a nuclear reactor component.
"""
function makenuclear(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; integercap=false, integeruc=false, cap=nothing, mincap=nothing, maxcap=nothing, warmstart=nothing, uc=false, fuelnode=nothing, capex_mult=1., fuel_mult=1., ini::Union{Nothing,Snapshot}=nothing, co2price=s.sim.options["CO2 price"])
    if tech in ("Nuclear", "Nuclear flexible",)
        reloading = 30 * 24 # hours
    elseif tech == "SMR"
        reloading = 15 * 24 # hours
    else
        throw(AssertionError("technology " * tech * " not recognized"))
    end
    
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = gettechparam(s, tech, "overnight_cost", "dispatchable") * 1000.
    _lt = Int(gettechparam(s, tech, "lifetime", "dispatchable"))
    _cp = gettechparam(s, tech, "construction_profile", "dispatchable")
    push!(vb, FixedCost(:investment, "output", energy, eac(_oc , s.options["discountrate"], _lt, _cp) * capex_mult))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, tech, "om_fixed_cost", "dispatchable") * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, gettechparam(s, tech, "om_var_cost", "dispatchable")))
    push!(vb, VariableCost(:waste, "output", energy, gettechparam(s, tech, "waste_cost", "dispatchable")))
    # fuel cost only used is fuel node is nothing
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, gettechparam(s, tech, "decommissioning", "dispatchable"), _lt, s.options["discountrate"]) * capex_mult))
    if !iszero(gettechparam(s, tech, "co2_emission", "dispatchable"))
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x * gettechparam(s, tech, "co2_emission", "dispatchable") / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    _usize = iszero(gettechparam(s, tech, "unit_size", "dispatchable")) ? nothing : gettechparam(s, tech, "unit_size", "dispatchable")
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
        push!(vb, VariableCost(:fuel, "output", energy, gettechparam(s, tech, "fuel_cost", "dispatchable") * fuel_mult))
    else
        @assert !ismissing(gettechparam(s, tech, "efficiency", "dispatchable")) "Please define the `efficiency` parameter for $name in technological data file."
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x / gettechparam(s, tech, "efficiency", "dispatchable")))
    end

    # special case: cycling constraints for nuclear
    if uc
        if isnothing(ini)
            push!(vb, Nosy.UnitCommitment("output", 
                gettechparam(s, tech, "min_power", "dispatchable"), 
                uptime=gettechparam(s, tech, "min_uptime", "dispatchable"), 
                downtime=[gettechparam(s, tech, "min_downtime", "dispatchable"), reloading], 
                #downtime2=876, # 24*30, 
                startup=gettechparam(s, tech, "startup_duration", "dispatchable"), 
                shutdown=gettechparam(s, tech, "shutdown_duration", "dispatchable"), 
                integer=integeruc)
            )
            push!(vb, NoLoadCost(:noload, "output", gettechparam(s, tech, "no_load_cost", "dispatchable")))
            push!(vb, StartupCost(:startup, "output", gettechparam(s, tech, "startup_cost", "dispatchable")))
        elseif Nosy.hascomponent(ini, name * " " * elec.name)
            push!(vb, NoLoadCost(:noload, "output", gettechparam(s, tech, "no_load_cost", "dispatchable")))
            push!(vb, StartupCost(:startup, "output", gettechparam(s, tech, "startup_cost", "dispatchable")))
            push!(vb, UnitCommitment(first(Nosy.getbehaviors(ini.components[name * " " * elec.name], Nosy.FleetUnitCommitmentBehavior))))
        else
            uc = false # not considering uc for the rest of the method
        end
    end

    c = Component(name * " " * elec.name, m, vb)
    for t in (:generation, :dispatchable)
        tag!(c, t)
    end
    connect!(s, c, elec)
    if !iszero(gettechparam(s, tech, "co2_emission", "dispatchable"))
        connect!(s, c, co2)
    end
    if !isnothing(fuelnode)
        connect!(s, c, fuelnode)
    end

    # load-following using startup and shutdown
    # if uc
    #     sum_reload = AffExpr(0.)
    #     for h in 1:8760
    #         # reduce possibilities for reloading-type shutdown
    #         if !iszero((h-1)%(6))
    #             e = c.behaviors[2].shutdownselector[1][h]
    #             if e isa GenericAffExpr
    #                 v = first(e.terms)[1]
    #                 fix(v, 0., force=true)
    #             end
    #         end
    #     end
    # end

    if tech in ("Nuclear", "Nuclear flexible",)
        # reduce capabilities of short shutdown
        if uc
            for h in 1:8760
                # reduce possibilities for reloading-type shutdown
                if !iszero((h-1)%(12))
                    # reduce possibilities for startup
                    e = c.behaviors[2].startup[h]
                    if (e isa GenericAffExpr) && !iszero(e)
                        v = first(e.terms)[1]
                        fix(v, 0., force=true)
                    end                

                    # reduce possibilities for normal shutdown
                    e = c.behaviors[2].shutdownselector[1][h]
                    if (e isa GenericAffExpr) && !iszero(e)
                        v = first(e.terms)[1]
                        fix(v, 0., force=true)
                    end
                end
            end
        end

        # reloading of nuclear fuel
        if uc
            sum_reload = AffExpr(0.)
            for h in 1:8760
                # reduce possibilities for reloading-type shutdown
                if !iszero((h-1)%(24*7))
                    e = c.behaviors[2].shutdownselector[2][h]
                    if (e isa GenericAffExpr) && !iszero(e)
                        v = first(e.terms)[1]
                        fix(v, 0., force=true)
                    end
                else
                    add_to_expression!(sum_reload, c.behaviors[2].shutdownselector[2][h])
                end
            end
            @constraint(s.sim.model, sum_reload == nbunits(c))
        end
    elseif tech == "SMR"
        # reloading of nuclear fuel
        if uc
            sum_reload = AffExpr(0.)
            for h in 1:8760
                add_to_expression!(sum_reload, c.behaviors[2].shutdownselector[2][h])
            end
            @constraint(s.sim.model, sum_reload == nbunits(c))
        end
    end

    return c
end

"""
    makesmr(name::String, tech::String, elec::Node, co2::Node, cap, s::Snapshot; integer=false)
Build, connect and return an SMR component.
"""
function makesmr(name::String, tech::String, elec::Node, heat::Node, s::Snapshot; integercap=false, integeruc=false, cap=nothing, mincap=nothing, maxcap=nothing, warmstart=nothing, uc=false, fuelnode=nothing, capex_mult=1., ini::Union{Nothing,Snapshot}=nothing, co2price=s.sim.options["CO2 price"])
    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = gettechparam(s, tech, "overnight_cost", "dispatchable") * 1000. / 0.9 # integrate 10% of offtime for reloading
    _lt = Int(gettechparam(s, tech, "lifetime", "dispatchable"))
    _cp = gettechparam(s, tech, "construction_profile", "dispatchable")
    push!(vb, FixedCost(:investment, "output", energy, eac(_oc , s.options["discountrate"], _lt, _cp) * capex_mult))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, tech, "om_fixed_cost", "dispatchable") * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, gettechparam(s, tech, "om_var_cost", "dispatchable")))
    push!(vb, VariableCost(:waste, "output", energy, gettechparam(s, tech, "waste_cost", "dispatchable")))
    # fuel cost only used is fuel node is nothing
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, gettechparam(s, tech, "decommissioning", "dispatchable"), _lt, s.options["discountrate"]) * capex_mult))
    
    push!(vb, LinkedJointFlow("heat", heat.carrier, :output, "output", x->x * 1)) # actually not heat, but modeled as a 1:1 ratio to keep track of SMR and align it with HTE 
    
    _usize = iszero(gettechparam(s, tech, "unit_size", "dispatchable")) ? nothing : gettechparam(s, tech, "unit_size", "dispatchable")
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
    


    return c
end

"""
    makenuclearprofile(name::String, tech::String, elec::Node, co2::Node, cap, s::Snapshot)
Build, connect and return a dispatchable component.
"""
function makenuclearprofile(name::String, tech::String, elec::Node, co2::Node, cap, s::Snapshot)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech, "profiles") / cap)
    vb = []
    _oc = 1E3 * gettechparam(s, tech, "overnight_cost", "dispatchable")
    _lt = Int(gettechparam(s, tech, "lifetime", "dispatchable"))
    _cp = gettechparam(s, tech, "construction_profile", "dispatchable")
    push!(vb, FixedCost(:investment, "output", energy, eac(_oc, s.options["discountrate"], gettechparam(s, tech, "lifetime", "dispatchable"), _cp)))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, tech, "om_fixed_cost", "dispatchable") * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, gettechparam(s, tech, "om_var_cost", "dispatchable")))
    push!(vb, VariableCost(:fuel, "output", energy, gettechparam(s, tech, "fuel_cost", "dispatchable")))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, gettechparam(s, tech, "decommissioning", "dispatchable"), _lt, s.options["discountrate"])))
    if !iszero(gettechparam(s, tech, "co2_emission", "dispatchable"))
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x * gettechparam(s, tech, "co2_emission", "dispatchable") / 1000.))
    end
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    elseif isnothing(cap)
        push!(vb, VariableCapacity("output", energy))
    end
    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    if !iszero(gettechparam(s, tech, "co2_emission", "dispatchable"))
        connect!(s, c, co2)
    end
    for t in (:generation, :dispatchable, :carbonfree,)
        tag!(c, t)
    end
    return c
end

function makereservoirprofile(name::String, tech::String, elec::Node, cap, s::Snapshot)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech, "fixed_reservoir_output") / cap)
    vb = []
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    elseif isnothing(cap)
        push!(vb, VariableCapacity("output", energy))
    end
    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:generation, :dispatchable, :carbonfree,)
        tag!(c, t)
    end
    return c
end

"""
    makeintermittentsource(name::String, tech::String, elec::Node, cap, s::Snapshot)
Build, connect and return an intermittent source component.
"""
function makeintermittentsource(name::String, tech::String, elec::Node, co2::Node, s::Snapshot; cap=nothing, mincap=nothing, maxcap=nothing, capex_mult=1., weatheryear=2009, ini::Union{Nothing,Snapshot}=nothing)
    m = ProfileSource(elec.carrier, gettimeseries(s, tech * "_" * elec.name, "profiles_" * string(weatheryear)))
    vb = []
    _cp = gettechparam(s, tech, "construction_profile", "profile")
    _inv = 1E3 * eac(gettechparam(s, tech, "overnight_cost", "profile"), s.options["discountrate"], gettechparam(s, tech, "lifetime", "profile"), _cp) * capex_mult
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, tech, "om_fixed_cost", "profile") * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, gettechparam(s, tech, "om_var_cost", "profile")))
    push!(vb, VariableCost(:fuel, "output", energy, gettechparam(s, tech, "fuel_cost", "profile")))
    push!(vb, FixedCost(:decommissioning, "output", energy, gettechparam(s, tech, "decommissioning", "profile") * _inv))
    if !iszero(gettechparam(s, tech, "co2_emission", "profile"))
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x * gettechparam(s, tech, "co2_emission", "profile") / 1000.))
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
    if !iszero(gettechparam(s, tech, "co2_emission", "profile"))
        connect!(s, c, co2)
    end
    for t in (:generation, :intermittent, :carbonfree,)
        tag!(c, t)
    end
    return c
end

"""
    makehydroror(name::String, zone::String, elec::Node, cap, s::Snapshot; weatheryear=2019)
Build, connect and return a run-of-river hydro component.
"""
function makehydroror(name::String, zone::String, elec::Node, cap, s::Snapshot; weatheryear=2019, intake_mult=1.)
    _profile = gettimeseries(s, zone, "hydro_ror_$weatheryear")
    m = ProfileSource(elec.carrier, _profile * intake_mult / cap, cutoff=1.)
    vb = []
    if cap isa Number
        push!(vb, FixedCapacity("output", energy, cap))
    elseif isnothing(cap)
        push!(vb, VariableCapacity("output", energy))
    end

    # costs
    _oc = gettechparam(s, "Hydro ror", "overnight_cost", "profile") * 1000.
    _lt = Int(gettechparam(s, "Hydro ror", "lifetime", "profile"))
    _cp = gettechparam(s, "Hydro ror", "construction_profile", "profile")
    push!(vb, FixedCost(:investment, "output", energy, eac(_oc , s.options["discountrate"], _lt, _cp)))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, "Hydro ror", "om_fixed_cost", "profile") * 1000.))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, gettechparam(s, "Hydro ror", "decommissioning", "profile"), _lt, s.options["discountrate"])))

    c = Component(name * " " * elec.name, m, vb)
    connect!(s, c, elec)
    for t in (:generation, :intermittent, :carbonfree)
        tag!(c, t)
    end
    return c
end

"""
    makehydroreservoir(name::String, zone::String, elec::Node, cap_discharging, cap_charging, inflow::Number, s::Snapshot)
Build, connect and return a hydro reservoir component.
NB: no energy capacity at the moment.
"""
function makehydroreservoir(name::String, tech::String, zone::String, elec::Node, cap_discharging, cap_charging, cap_reservoir, inflow, s::Snapshot; renormalize=true, weatheryear=2019, gridlosses=0., simplified=false, intake_mult=1.)
    m = LazyStorage(elec.carrier, eff=Dict("natural" => 1., "output" => 1., "input" => 0.76, "grid losses" => 0.), simplified=simplified)
    vb = []
    # joint flows for input and output
    push!(vb, FreeJointFlow("output", elec.carrier, :output))

    # costs
    _oc = gettechparam(s, tech, "overnight_cost", "storage") * 1000.
    _lt = Int(gettechparam(s, tech, "lifetime", "storage"))
    _cp = gettechparam(s, tech, "construction_profile", "storage")
    push!(vb, FixedCost(:investment, "output", energy, eac(_oc , s.options["discountrate"], _lt, _cp)))
    push!(vb, FixedCost(:fom, "output", energy, gettechparam(s, tech, "om_fixed_cost", "storage") * 1000.))
    push!(vb, FixedCost(:decommissioning, "output", energy, decom_cost(_oc, gettechparam(s, tech, "decommissioning", "storage"), _lt, s.options["discountrate"])))
    
    

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
            !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x * gridlosses))
        end
    elseif isnothing(cap_charging)
        push!(vb, VariableCapacity("input", energy))
        !iszero(gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x * gridlosses))
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
    makebatteries(name::String, tech::String, elec::Node, cap, s::Snapshot, maxcap=nothing)
Build, connect and return a battery storage component.
"""
function makebatteries(name::String, tech::String, elec::Node, capin, s::Snapshot; eff=0.85, hours=4, gridlosses=0., capex_mult=1, simplified::Bool=false, ini::Union{Nothing,Snapshot}=nothing)
    _cp = gettechparam(s, tech, "construction_profile", "storage")
    _inv = 1E3 * eac(gettechparam(s, tech, "overnight_cost", "storage"), s.options["discountrate"], gettechparam(s, tech, "lifetime", "storage"), _cp) * capex_mult
    m = BasicStorage(elec.carrier, eff_i=eff, simplified=simplified)
    vb = []
    
    push!(vb, Duration(hours))
    if capin isa Number
        push!(vb, FixedCapacity("input", energy, capin))
    else
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, name * " " * elec.name)))
        end
    end
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, VariableCost(:vom, "input", energy, gettechparam(s, tech, "om_var_cost", "storage")))

    if !iszero(gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x * gridlosses))
    end

    c = Component(name * " " * elec.name, m, vb)

    for t in (:electricity, :storage, :generation)
        tag!(c, t)
    end
    connect!(s, c, elec)
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
function makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot; dir::Bool=false, transactioncost::Number=1., foreign::Bool=true)
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
end

"""
    makenodeinterco(name::String, a::Node, b::Node, mcap::Number, xcap::Number, s::Snapshot)
Build, connect and return an interconnection component linking two nodes.
If `dir` is true, apply a one-way constraint at every timestep.
"""
function makenodeinterco(name::String, a::Node, b::Node, atob::Number, btoa::Number, s::Snapshot; dir::Bool=false, foreign::Bool=false, transactioncost=1., dc::Bool=false)
    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1.)
    
    if !isinf(atob)
        push!(vb, FixedCapacity("input", energy, atob))
        push!(vb, Nosy.CapacityMultiplier("input", gettimeseries(s, a.name * ">" * b.name, "transfer_capacities", digits=2)))
        push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))
    end

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x))
    if !isinf(btoa)
        push!(vb, FixedCapacity("input2", energy, btoa))
        push!(vb, Nosy.CapacityMultiplier("input2", gettimeseries(s, b.name * ">" * a.name, "transfer_capacities", digits=2)))
        push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))
    end
    
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
    makeelectrolyser(name::String, elec::Node, h2::Node, cap, s::Snapshot; integer=false)
Build, connect and return an electrolyser component.
"""
function makeelectrolyser(name::String, tech::String, elec::Node, h2::Node, cap, s::Snapshot; maxcap=nothing, gridlosses=0., capex_mult=1., ini::Union{Nothing,Snapshot}=nothing)
    m = BasicConverter(elec.carrier, h2.carrier, ratio=0.7)
    vb = []
    _cp = gettechparam(s, tech, "construction_profile", "electrolysis")
    _inv = 1E3 * eac(gettechparam(s, tech, "overnight_cost", "electrolysis"), s.options["discountrate"], gettechparam(s, tech, "lifetime", "electrolysis"), _cp) * capex_mult
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:decommissioning, "input", energy, gettechparam(s, tech, "decommissioning", "electrolysis") * _inv))
    push!(vb, FixedCost(:fom, "input", energy, gettechparam(s, tech, "om_fixed_cost", "electrolysis") * 1000.))
    push!(vb, VariableCost(:vom, "input", energy, gettechparam(s, tech, "om_var_cost", "electrolysis")))
    if cap isa Number
        push!(vb, FixedCapacity("input", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, name * " " * elec.name)))
        end
    end
    if !iszero(gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x * gridlosses))
    end

    c = Component(name * " " * elec.name, m, vb)
    for t in (:electrolysis, :hydrogen)
        tag!(c, t)
    end
    connect!(s, c, elec)
    connect!(s, c, h2)
    return c
end

"""
    makeHTelectrolyser(name::String, elec::Node, h2::Node, cap, s::Snapshot; integer=false)
Build, connect and return an HT electrolyser component.
"""
function makeHTelectrolyser(name::String, tech::String, elec::Node, heat::Node, h2::Node, cap, s::Snapshot; maxcap=nothing, gridlosses=0., capex_mult=1., ini::Union{Nothing,Snapshot}=nothing)
    m = BasicConverter(elec.carrier, h2.carrier, ratio=0.9)
    vb = []
    _cp = gettechparam(s, tech, "construction_profile", "electrolysis")
    _inv = 1E3 * eac(gettechparam(s, tech, "overnight_cost", "electrolysis"), s.options["discountrate"], gettechparam(s, tech, "lifetime", "electrolysis"), _cp) * capex_mult
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:decommissioning, "input", energy, gettechparam(s, tech, "decommissioning", "electrolysis") * _inv))
    push!(vb, FixedCost(:fom, "input", energy, gettechparam(s, tech, "om_fixed_cost", "electrolysis") * 1000.))
    push!(vb, VariableCost(:vom, "input", energy, gettechparam(s, tech, "om_var_cost", "electrolysis")))
    if cap isa Number
        push!(vb, FixedCapacity("input", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, name * " " * elec.name)))
        end
    end

    # heat from SMR
    push!(vb, LinkedJointFlow("heat", heat.carrier, :input, "input", x->x))

    if !iszero(gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x * gridlosses))
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
    makehydrogenstorage(name::String, tech::String, h2::Node, cap, s::Snapshot, maxcap=nothing)
Build, connect and return a hydrogen storage component.
"""
function makehydrogenstorage(name::String, tech::String, h2::Node, cap, eff::Number, s::Snapshot, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing)
    m = BasicStorage(h2.carrier, eff_i=eff, simplified=true) # always simplified because this is at least medium-term storage (>day)
    vb = []
    if cap isa Number
        push!(vb, FixedCapacity("level", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("level", energy, integer=false, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("level", energy, capacity(name * " " * h2.name)))
        end
    end
    # push!(vb, Duration(4)) # TYNDP methodology 9.6.4: fill in 4 hours # removed for large storage (no meaning, no impact except negative on performance)
    c = Component(name * " " * h2.name, m, vb)
    for t in (:hydrogen, :storage)
        tag!(c, t)
    end
    connect!(s, c, h2)
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