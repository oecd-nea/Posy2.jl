"""
Generate conversion components.
"""

"""
    makeelectrolyser(cname::String, techkey::String, elec::Node, h2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, ini=nothing,
        gridlosses=0.,
        eff::Union{Nothing,Real}=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        om_var_cost::Union{Nothing,Real}=nothing,
    )

Build, connect and return an electrolyser component.

Arguments:
  * `cname`: component name prefix.
  * `techkey`: technology column name in the `electrolysis` tech data sheet.
  * `elec`: electricity node to connect the component to.
  * `h2`: hydrogen node to connect the component to.
  * `s`: snapshot to register the component in.

  * `cap`: Fixed electrolyser input capacity. If `nothing`, input capacity is optimized.
  * `mincap`: Bounds for optimized input capacity when `cap === nothing`.
  * `maxcap`: Bounds for optimized input capacity when `cap === nothing`.
  * `ini`: Optional initial snapshot used to inherit fixed input capacity.

  * `gridlosses`: Proportional losses linked to electricity input flow (`0 <= gridlosses < 1`).
  * `eff`: Electricity to hydrogen conversion ratio in `BasicConverter`. If `nothing`, read `efficiency` from the `electrolysis` sheet.

  * `overnight_cost`: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `om_fixed_cost`: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning`: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `lifetime`: CAPEX/FOM/lifetime inputs for annualized fixed cost terms (`> 0`, integer-valued). Workbook defaults are used when values are `nothing`.
  * `construction_profile`: CAPEX/FOM/lifetime inputs for annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning_profile`: Decommissioning cost share profile passed to `decom_cost(...)`. Workbook defaults are used when values are `nothing`.
  * `om_var_cost`: Variable O&M coefficient on input energy flow.
"""
function makeelectrolyser(cname::String, techkey::String, elec::Node, h2::Node, s::Snapshot;
    # capacity / expansion
    cap::Union{Nothing,Real}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    ini::Union{Nothing,Snapshot}=nothing, gridlosses::Real=0.,

    # technical overrides
    eff::Union{Nothing,Real}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    om_var_cost::Union{Nothing,Real}=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _eff = isnothing(eff) ? gettechparam(s, techkey, "efficiency", "electrolysis") : eff
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, techkey, "overnight_cost", "electrolysis") : overnight_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, techkey, "decommissioning", "electrolysis") : decommissioning
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, techkey, "om_fixed_cost", "electrolysis") : om_fixed_cost
        _vom = isnothing(om_var_cost) ? gettechparam(s, techkey, "om_var_cost", "electrolysis") : om_var_cost
    else
        _eff = something(eff, 1.0)
        _oc_raw = something(overnight_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _vom = something(om_var_cost, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, techkey, "lifetime", "electrolysis") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, techkey, "construction_profile", "electrolysis") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, techkey, "decommissioning_profile", "electrolysis") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        gridlosses=gridlosses, efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        decommissioning=_decom, om_fixed_cost=_fom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _gridlosses = Float64(gridlosses)
    _eff = Float64(_eff)
    m = BasicConverter(elec.carrier, h2.carrier, ratio=_eff)
    vb = []
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discountrate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discountrate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:decommissioning, "input", energy, _decom_cost))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "input", energy, _vom))
    if cap isa Real
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
