"""
Generate storage components.
"""

using ArgCheck: @argcheck

"""
    makehydroreservoir(cname::String, tech::String, zone::String, elec::Node,
        cap_discharging, cap_charging, cap_reservoir, inflow, s::Snapshot;
        renormalize=true, weatheryear=2019, gridlosses=0., simplified=false, intake_mult=1.,
        capex_mult=1.,
        eff=nothing,
        overnight_cost=nothing, om_fixed_cost=nothing, om_var_cost=nothing, decommissioning=nothing, lifetime=nothing,
        construction_profile=nothing,
    )

Build, connect and return a hydro reservoir component.
NB: no energy capacity at the moment.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `storage` tech data sheet.
  * zone: Zone used for reservoir inflow time series lookup.
  * elec: electricity node to connect the component to.
  * s: snapshot to register the component in.
  * cap_discharging: Discharge side capacity (output port). If `nothing`, discharge capacity is optimized.
  * cap_charging: Charge side capacity (input port). `0` disables charging branch; `nothing` optimizes charging capacity.
  * cap_reservoir: Storage level capacity (energy stock).
  * inflow: Natural inflow control: `nothing` uses raw profile, `0` disables inflow, numeric scales annual inflow.

  * renormalize: If `true`, inflow profile is normalized to sum to 1 before scaling with `inflow`.
  * weatheryear: Year suffix used to select inflow series `reservoir_inflow_<year>`.
  * gridlosses: Proportional losses linked to charging input flow (`0 <= gridlosses < 1`).
  * simplified: Passed to `LazyStorage(..., simplified=...)`.
  * intake_mult: Multiplier applied to inflow profile.

  * capex_mult: Scenario multiplier on annualized investment related costs.
  * eff: Roundtrip charging efficiency (input side conversion).

  * overnight_cost: Cost/lifetime overrides for annualized fixed and variable cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: Cost/lifetime overrides for annualized fixed and variable cost terms. Excel defaults are used when values are `nothing`.
  * om_var_cost: Cost/lifetime overrides for annualized fixed and variable cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: Cost/lifetime overrides for annualized fixed and variable cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: Cost/lifetime overrides for annualized fixed and variable cost terms. Excel defaults are used when values are `nothing`.
  * construction_profile: Cost/lifetime overrides for annualized fixed and variable cost terms. Excel defaults are used when values are `nothing`.
"""
function makehydroreservoir(cname::String, tech::String, zone::String, elec::Node, cap_discharging, cap_charging, cap_reservoir, inflow, s::Snapshot;
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
    @argcheck gridlosses isa Real "gridlosses must be Real."
    @argcheck 0 <= gridlosses < 1 "gridlosses must be in [0, 1)."
    _gridlosses = Float64(gridlosses)
    _eff = isnothing(eff) ? gettechparam(s, tech, "roundtrip_eff", "storage") : eff
    @argcheck _eff isa Real "eff must be Real."
    @argcheck 0 < _eff <= 1 "eff must be in (0, 1]."
    _eff = Float64(_eff)
    m = LazyStorage(elec.carrier, eff=Dict("natural" => 1., "output" => 1., "input" => _eff, "grid losses" => 0.), simplified=simplified)
    vb = []
    # joint flows for input and output
    push!(vb, FreeJointFlow("output", elec.carrier, :output))

    # costs
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "storage") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
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
        throw(ArgumentError("cap_discharging is not a number or nothing"))
    end
    if cap_charging isa Number 
        if iszero(cap_charging)
            # charging capacity is not added
            nothing
        else
            push!(vb, FreeJointFlow("input", elec.carrier, :input))
            push!(vb, FixedCapacity("input", energy, cap_charging))
            !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))
        end
    elseif isnothing(cap_charging)
        push!(vb, VariableCapacity("input", energy))
        !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))
    else
        throw(ArgumentError("cap_charging is not a number or nothing"))
    end
    
    if cap_reservoir isa Number
        push!(vb, FixedCapacity("level", energy, cap_reservoir))
    else
        nothing
        # throw(error("cap_reservoir is not a number"))
    end

    c = Component(cname * " " * elec.name, m, vb)
    
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
    makebatteries(cname::String, tech::String, elec::Node, s::Snapshot;
        capin=nothing, mincap=nothing, maxcap=nothing, simplified=false, ini=nothing,
        gridlosses=0., capex_mult=1,
        eff=nothing, duration=nothing,
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
        connection_cost=nothing, om_var_cost=nothing,
    )

Build, connect and return a battery storage component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `storage` tech data sheet.
  * elec: electricity node to connect the component to.
  * s: snapshot to register the component in.

  * capin: Fixed charging/input capacity. If `nothing`, charging capacity is optimized.
  * mincap: Bounds for optimized `capin` when `capin === nothing`.
  * maxcap: Bounds for optimized `capin` when `capin === nothing`.
  * simplified: Passed to `BasicStorage(..., simplified=...)`.
  * ini: Optional initial snapshot used to inherit fixed charging capacity.

  * gridlosses: Proportional losses linked to charging input flow (`0 <= gridlosses < 1`).
  * capex_mult: Scenario multiplier on annualized investment related costs.

  * eff: Roundtrip storage efficiency (`eff_i` in `BasicStorage`).
  * duration: Storage duration parameter (`Duration(...)` behavior). Excel default when `nothing`.

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * connection_cost: Ratio applied to annualized investment as connection fixed cost.
  * om_var_cost: Variable O&M coefficient on charging/input energy flow.
"""
function makebatteries(cname::String, tech::String, elec::Node, s::Snapshot;
    # capacity / expansion
    capin=nothing, mincap=nothing, maxcap=nothing, simplified::Bool=false, ini::Union{Nothing,Snapshot}=nothing,

    # scenario controls
    gridlosses=0., capex_mult=1,

    # technical overrides
    eff=nothing, duration=nothing,

    # economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    connection_cost=nothing, om_var_cost=nothing,
)
    @argcheck gridlosses isa Real "gridlosses must be Real."
    @argcheck 0 <= gridlosses < 1 "gridlosses must be in [0, 1)."
    _gridlosses = Float64(gridlosses)
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "storage") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "storage") : construction_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp) * capex_mult
    _eff = isnothing(eff) ? gettechparam(s, tech, "roundtrip_eff", "storage") : eff
    @argcheck _eff isa Real "eff must be Real."
    @argcheck 0 < _eff <= 1 "eff must be in (0, 1]."
    _eff = Float64(_eff)
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
            push!(vb, FixedCapacity("input", energy, capacity(ini, cname * " " * elec.name)))
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

    if !iszero(_gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))
    end

    c = Component(cname * " " * elec.name, m, vb)

    for t in (:electricity, :storage, :generation)
        tag!(c, t)
    end
    connect!(s, c, elec)

    return c
end

"""
    makehydrogenstorage(cname::String, tech::String, h2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing,
        capex_mult=1.,
        eff=nothing,
        overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
    )

Build, connect and return a hydrogen storage component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `storage` tech data sheet.
  * h2: hydrogen node to connect the component to.
  * s: snapshot to register the component in.

  * cap: Fixed storage level capacity. If `nothing`, level capacity is optimized.
  * mincap: Bounds for optimized level capacity when `cap === nothing`.
  * maxcap: Bounds for optimized level capacity when `cap === nothing`.
  * ini: Optional initial snapshot used to inherit fixed level capacity.

  * capex_mult: Scenario multiplier on annualized investment related costs.
  * eff: Roundtrip storage efficiency (`eff_i` in `BasicStorage`). If `nothing`, read from Excel (`storage.roundtrip_eff`).

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
"""
function makehydrogenstorage(cname::String, tech::String, h2::Node, s::Snapshot;
    # capacity / expansion
    cap=nothing, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing,

    # scenario controls
    capex_mult=1.,

    # technical overrides
    eff=nothing,

    # economic overrides
    overnight_cost=nothing, om_fixed_cost=nothing, decommissioning=nothing, lifetime=nothing, construction_profile=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "roundtrip_eff", "storage") : eff
    @argcheck _eff isa Real "eff must be Real."
    @argcheck 0 < _eff <= 1 "eff must be in (0, 1]."
    _eff = Float64(_eff)
    m = BasicStorage(h2.carrier, eff_i=_eff, simplified=true) # always simplified for this medium or long term storage archetype
    vb = []
    _oc = (isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "storage") : overnight_cost) * 1000.
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "storage") : lifetime
    @argcheck _lt_raw isa Real "lifetime must be Real."
    @argcheck _lt_raw > 0 "lifetime must be > 0."
    @argcheck isinteger(_lt_raw) "lifetime must be integer-valued."
    _lt = Int(_lt_raw)
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
        elseif Nosy.hascomponent(ini, cname * " " * h2.name)
            push!(vb, FixedCapacity("level", energy, capacity(ini, cname * " " * h2.name)))
        else
            push!(vb, FixedCapacity("level", energy, 0.))
        end
    end
    # push!(vb, Duration(4)) # TYNDP methodology 9.6.4: fill in 4 hours # removed for large storage (no meaning, no impact except negative on performance)
    c = Component(cname * " " * h2.name, m, vb)
    for t in (:hydrogen, :storage)
        tag!(c, t)
    end
    connect!(s, c, h2)
    return c
end
