"""
Generate conversion components.
"""

"""
    makeelectrolyser(cname::String, tech::String, elec::Node, h2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing,
        gridlosses=0.,
        eff::Union{Nothing,Number}=nothing,
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        om_var_cost::Union{Nothing,Number}=nothing,
    )

Build, connect and return an electrolyser component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `electrolysis` tech data sheet.
  * elec: electricity node to connect the component to.
  * h2: hydrogen node to connect the component to.
  * s: snapshot to register the component in.

  * cap: Fixed electrolyser input capacity. If `nothing`, input capacity is optimized.
  * mincap: Bounds for optimized input capacity when `cap === nothing`.
  * maxcap: Bounds for optimized input capacity when `cap === nothing`.
  * ini: Optional initial snapshot used to inherit fixed input capacity.

  * gridlosses: Proportional losses linked to electricity input flow (`0 <= gridlosses < 1`).
  * eff: Electricity to hydrogen conversion ratio in `BasicConverter`. If `nothing`, read from Excel (`electrolysis.efficiency`).

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs for annualized fixed cost terms (`> 0`, integer-valued). Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. Excel defaults are used when values are `nothing`.
  * om_var_cost: Variable O&M coefficient on input energy flow.
"""
function makeelectrolyser(cname::String, tech::String, elec::Node, h2::Node, s::Snapshot;
    # capacity / expansion
    cap=nothing, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, gridlosses=0.,

    # technical overrides
    eff::Union{Nothing,Number}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    om_var_cost::Union{Nothing,Number}=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "efficiency", "electrolysis") : eff
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "electrolysis") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "electrolysis") : lifetime
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "electrolysis") : decommissioning
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "electrolysis") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "electrolysis") : om_var_cost
    inputs = component_input(
        gridlosses=gridlosses, efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        decommissioning=_decom, om_fixed_cost=_fom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _gridlosses = Float64(gridlosses)
    _eff = Float64(_eff)
    m = BasicConverter(elec.carrier, h2.carrier, ratio=_eff)
    vb = []
    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "electrolysis") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "electrolysis") : decommissioning_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:decommissioning, "input", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "input", energy, _vom))
    if cap isa Number
        push!(vb, FixedCapacity("input", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, cname * " " * elec.name)))
        end
    end
    if !iszero(_gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))
    end

    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    for t in ("demand", "electrolysis", "hydrogen")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    connect!(s, c, h2)
    return c
end

"""
    makeHTelectrolyser(cname::String, tech::String, elec::Node, heat::Node, h2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing,
        gridlosses=0.,
        eff::Union{Nothing,Number}=nothing,
        overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
        decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        om_var_cost::Union{Nothing,Number}=nothing,
    )

Build, connect and return an HT electrolyser component.

Arguments:
  * cname: component name prefix.
  * tech: technology row name in the `electrolysis` tech data sheet.
  * elec: electricity node to connect the component to.
  * heat: Heat node. It is linked one to one to electrolyser input via `LinkedJointFlow("heat", ...)`.
  * h2: hydrogen node to connect the component to.
  * s: snapshot to register the component in.

  * cap: Fixed electrolyser input capacity. If `nothing`, input capacity is optimized.
  * mincap: Bounds for optimized input capacity when `cap === nothing`.
  * maxcap: Bounds for optimized input capacity when `cap === nothing`.
  * ini: Optional initial snapshot used to inherit fixed input capacity.

  * gridlosses: Proportional losses linked to electricity input flow (`0 <= gridlosses < 1`).
  * eff: Electricity to hydrogen conversion ratio in `BasicConverter`. If `nothing`, read from Excel (`electrolysis.efficiency`).

  * overnight_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * om_fixed_cost: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * lifetime: CAPEX/FOM/lifetime inputs for annualized fixed cost terms (`> 0`, integer-valued). Excel defaults are used when values are `nothing`.
  * construction_profile: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Excel defaults are used when values are `nothing`.
  * decommissioning_profile: Decommissioning cost share profile passed to `decom_cost(...)`. Excel defaults are used when values are `nothing`.
  * om_var_cost: Variable O&M coefficient on input energy flow.
"""
function makeHTelectrolyser(cname::String, tech::String, elec::Node, heat::Node, h2::Node, s::Snapshot;
    # capacity / expansion
    cap=nothing, mincap=nothing, maxcap=nothing, ini::Union{Nothing,Snapshot}=nothing, gridlosses=0.,

    # technical overrides
    eff::Union{Nothing,Number}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Number}=nothing, om_fixed_cost::Union{Nothing,Number}=nothing,
    decommissioning::Union{Nothing,Number}=nothing, lifetime::Union{Nothing,Number}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    om_var_cost::Union{Nothing,Number}=nothing,
)
    _eff = isnothing(eff) ? gettechparam(s, tech, "efficiency", "electrolysis") : eff
    _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech, "overnight_cost", "electrolysis") : overnight_cost
    _lt_raw = isnothing(lifetime) ? gettechparam(s, tech, "lifetime", "electrolysis") : lifetime
    _decom = isnothing(decommissioning) ? gettechparam(s, tech, "decommissioning", "electrolysis") : decommissioning
    _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech, "om_fixed_cost", "electrolysis") : om_fixed_cost
    _vom = isnothing(om_var_cost) ? gettechparam(s, tech, "om_var_cost", "electrolysis") : om_var_cost
    inputs = component_input(
        gridlosses=gridlosses, efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        decommissioning=_decom, om_fixed_cost=_fom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _gridlosses = Float64(gridlosses)
    _eff = Float64(_eff)
    m = BasicConverter(elec.carrier, h2.carrier, ratio=_eff)
    vb = []
    _oc = _oc_raw * 1000.
    _lt = Int(_lt_raw)
    _cp = isnothing(construction_profile) ? gettechparam(s, tech, "construction_profile", "electrolysis") : construction_profile
    _dcp = isnothing(decommissioning_profile) ? gettechparam(s, tech, "decommissioning_profile", "electrolysis") : decommissioning_profile
    _inv = eac(_oc, discountrate(s), _lt, _cp)
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:decommissioning, "input", energy, decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "input", energy, _vom))
    if cap isa Number
        push!(vb, FixedCapacity("input", energy, cap))
    elseif isnothing(cap)
        if isnothing(ini)
            push!(vb, VariableCapacity("input", energy, integer=false, lb = isnothing(mincap) ? 0 : mincap, ub = isnothing(maxcap) ? Inf : maxcap))
        else
            push!(vb, FixedCapacity("input", energy, capacity(ini, cname * " " * elec.name)))
        end
    end

    # heat from SMR
    push!(vb, LinkedJointFlow("heat", heat.carrier, :input, "input", x->x[1]))

    if !iszero(_gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))
    end

    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    for t in ("electrolysis", "hydrogen")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    connect!(s, c, heat)
    connect!(s, c, h2)
    return c
end
