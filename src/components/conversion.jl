"""
Generate conversion components.
"""

"""
    makeelectrolyser(name::String, elec::Node, h2::Node, s::Snapshot;
        tech::String=name, tech_column::String=tech,
        cap=nothing, mincap=nothing, maxcap=nothing,
        grid_losses=0.,
        efficiency::Union{Nothing,Real}=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        om_var_cost::Union{Nothing,Real}=nothing,
    )

Build, connect and return an electrolyser component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `tech_column`: technology column name in the `electrolysis` tech data sheet;
    defaults to `tech`.
  * `elec`: electricity node to connect the component to.
  * `h2`: hydrogen node to connect the component to.
  * `s`: snapshot to register the component in.

  * `cap`: Electricity input capacity in MW. A number fixes capacity, a JuMP
    `VariableRef` or `AffExpr` reuses that expression, `nothing` creates a
    capacity decision, and an extracted `Snapshot` inherits the capacity of
    `"<name> <node name>"` in it.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.

  * `grid_losses`: Proportional electricity-loss fraction (`0 <= grid_losses < 1`).
  * `efficiency`: Hydrogen output per unit of electricity input (dimensionless when
    both carriers use MWh). If `nothing`, read it from the workbook in `:excel`
    mode and use one in `:arguments` mode.

  * `overnight_cost`: Overnight CAPEX in currency/kW of electricity input capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of electricity input capacity.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.
  * `om_var_cost`: Variable O&M in currency/MWh of electricity input.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makeelectrolyser(name::String, elec::Node, h2::Node, s::Snapshot;
    tech::String=name, tech_column::String=tech,
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    grid_losses::Real=0.,

    # technical overrides
    efficiency::Union{Nothing,Real}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    om_var_cost::Union{Nothing,Real}=nothing,
)
    checkhorizon(s)
    excel = tech_mode(s) === :excel
    if excel
        _eff = isnothing(efficiency) ? gettechparam(s, tech_column, "efficiency", "electrolysis") : efficiency
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "electrolysis") : overnight_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "electrolysis") : decommissioning
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "electrolysis") : om_fixed_cost
        _vom = isnothing(om_var_cost) ? gettechparam(s, tech_column, "om_var_cost", "electrolysis") : om_var_cost
    else
        _eff = something(efficiency, 1.0)
        _oc_raw = something(overnight_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _vom = something(om_var_cost, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, tech_column, "lifetime", "electrolysis") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, tech_column, "construction_profile", "electrolysis") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, tech_column, "decommissioning_profile", "electrolysis") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        grid_losses=grid_losses, efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        decommissioning=_decom, om_fixed_cost=_fom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _grid_losses = Float64(grid_losses)
    _eff = Float64(_eff)
    m = BasicConverter(elec.carrier, h2.carrier, ratio=_eff)
    vb = []
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discount_rate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discount_rate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:decommissioning, "input", energy, _decom_cost))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "input", energy, _vom))
    push!(vb, gencapacity(cap, "input", s, name * " " * elec.name; mincap=mincap, maxcap=maxcap))
    if !iszero(_grid_losses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _grid_losses))
    end

    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)
    for t in ("demand", "electrolysis", "hydrogen")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    connect!(s, c, h2)
    return c
end
