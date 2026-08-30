"""
Generate storage components.
"""

"""
    makehydroreservoir(name::String, zone::String, elec::Node, s::Snapshot;
        tech::String=name, tech_column::String=tech,
        cap_discharging, cap_charging, intake,
        mincap_discharging=nothing, maxcap_discharging=nothing,
        mincap_charging=nothing, maxcap_charging=nothing,
        mincap_reservoir=nothing, maxcap_reservoir=nothing,
        cap_reservoir=Inf, spillage=false,
        weatheryear=nothing, gridlosses=0., simplified=false,
        intake_profile=nothing,
        eff::Union{Nothing,Real}=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing,
        construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a hydro reservoir component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `tech_column`: technology column name in the `storage` tech data sheet;
    defaults to `tech`.
  * `zone`: Zone used for reservoir intake time series lookup.
  * `elec`: electricity node to connect the component to.
  * `s`: snapshot to register the component in.
  * `cap_discharging`: Discharging capacity in MW. A number fixes capacity, a
    JuMP `VariableRef` or `AffExpr` reuses that expression, `nothing` creates a
    capacity decision, and an extracted `Snapshot` inherits the capacity of
    `"<name> <node name>"` in it.
  * `cap_charging`: Charging capacity in MW with the same choices. The `input`
    port is always created; numeric `0` gives it a zero capacity, so a
    turbine-only reservoir still reports a charging flow of zero.
  * `intake`: Total natural intake in MWh over the modeled profile (normally one
    year). `0` disables natural intake.

  * `mincap_discharging`, `maxcap_discharging`, `mincap_charging`,
    `maxcap_charging`: Power-capacity bounds in MW.
  * `mincap_reservoir`, `maxcap_reservoir`: Reservoir-energy bounds in MWh.
    Bounds are checked as assertions against fixed or inherited capacities.

  * `cap_reservoir`: Storage level capacity in MWh, with the same choices as
    `cap_discharging`, plus `Inf` (the default) which leaves the level
    unlimited by adding no level capacity behavior.
  * `spillage`: Add an unconnected, unlimited `spill` output that lets the
    reservoir release stored energy without generating. It defaults to `false`,
    which forces all natural intake to eventually become generation.

  * `weatheryear`: Year suffix used to select the intake series stored in
    `reservoir_inflow_<year>`. Required when `intake_profile` is read from the
    time-series workbook; unused when a profile is supplied explicitly or
    natural intake is disabled.
  * `gridlosses`: Proportional charging-loss fraction (`0 <= gridlosses < 1`).
  * `simplified`: Passed to `LazyStorage(..., simplified=...)`.
  * `intake_profile`: Dimensionless hourly natural-intake shape or scalar,
    nonnegative with a strictly positive sum. It is normalized to sum to one
    before `intake` is applied. If `nothing`, read `zone` from
    `reservoir_inflow_<weatheryear>`.

  * `eff`: Dimensionless round-trip charging efficiency.

  * `overnight_cost`: Overnight CAPEX in currency/kW of discharging capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of discharging capacity.
  * `om_var_cost`: Variable O&M in currency/MWh discharged.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makehydroreservoir(name::String, zone::String, elec::Node, s::Snapshot;
    tech::String=name, tech_column::String=tech,
    # capacities
    cap_discharging::Union{Nothing,Real,VariableRef,AffExpr,Snapshot},
    cap_charging::Union{Nothing,Real,VariableRef,AffExpr,Snapshot},
    intake::Real,
    mincap_discharging::Union{Nothing,Real}=nothing, maxcap_discharging::Union{Nothing,Real}=nothing,
    mincap_charging::Union{Nothing,Real}=nothing, maxcap_charging::Union{Nothing,Real}=nothing,
    mincap_reservoir::Union{Nothing,Real}=nothing, maxcap_reservoir::Union{Nothing,Real}=nothing,

    # storage operation controls
    cap_reservoir::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=Inf, spillage::Bool=false,
    weatheryear::Union{Nothing,Integer}=nothing, gridlosses::Real=0.,
    simplified::Bool=false,
    intake_profile=nothing,

    # technical overrides
    eff::Union{Nothing,Real}=nothing,

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    om_var_cost::Union{Nothing,Real}=nothing, decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing,
    construction_profile=nothing, decommissioning_profile=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _eff = isnothing(eff) ? gettechparam(s, tech_column, "roundtrip_eff", "storage") : eff
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "storage") : overnight_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "storage") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "storage") : decommissioning
        _vom = isnothing(om_var_cost) ? gettechparam(s, tech_column, "om_var_cost", "storage") : om_var_cost
    else
        _eff = something(eff, 1.0)
        _oc_raw = something(overnight_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _vom = something(om_var_cost, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, tech_column, "lifetime", "storage") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, tech_column, "construction_profile", "storage") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, tech_column, "decommissioning_profile", "storage") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        gridlosses=gridlosses, efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        om_fixed_cost=_fom, decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _gridlosses = Float64(gridlosses)
    _eff = Float64(_eff)
    _effs = Dict("natural" => 1., "output" => 1., "input" => _eff, "grid losses" => 0.)
    spillage && (_effs["spill"] = 1.)
    m = LazyStorage(elec.carrier, eff=_effs, simplified=simplified)
    vb = []
    # joint flows for input and output
    push!(vb, FreeJointFlow("output", elec.carrier, :output))
    # unconnected free output: releases stored energy without generating
    spillage && push!(vb, FreeJointFlow("spill", elec.carrier, :output, mustconnect=false))

    # costs
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discountrate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discountrate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "output", energy, _decom_cost))
    push!(vb, VariableCost(:vom, "output", energy, _vom))

    @argcheck isfinite(intake) && intake >= 0 "makehydroreservoir `intake` must be finite and non-negative."
    intake_series = if iszero(intake)
        zeros(Nosy.nhours(sim(s)))
    else
        if isnothing(intake_profile) && timeseries_mode(s) === :excel && isnothing(weatheryear)
            throw(ArgumentError(
                "`weatheryear` must be supplied when `intake_profile` is read from the time-series workbook",
            ))
        end
        profile_sheet = isnothing(weatheryear) ? nothing : "reservoir_inflow_$weatheryear"
        profile = _resolve_timeseries(
            s, intake_profile, zone, profile_sheet;
            keyword="intake_profile", lower=0.0,
        )
        profile_sum = sum(profile)
        @argcheck profile_sum > 0 "reservoir intake profile must have a positive sum."
        profile / profile_sum * intake
    end
    if !all(iszero, intake_series)
        push!(vb, FixedJointFlow("natural", elec.carrier, :input, intake_series, mustconnect=false))
    end
    
    push!(vb, gencapacity(cap_discharging, "output", s, name * " " * elec.name;
        mincap=mincap_discharging, maxcap=maxcap_discharging, argname="cap_discharging"))

    # the charging branch always exists, at zero capacity when charging is disabled
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, gencapacity(cap_charging, "input", s, name * " " * elec.name;
        mincap=mincap_charging, maxcap=maxcap_charging, argname="cap_charging"))
    !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))

    if cap_reservoir isa Real && cap_reservoir == Inf
        # unlimited level: no capacity behavior, but the bounds still assert on it
        _checkcapacitybounds(cap_reservoir, mincap_reservoir, maxcap_reservoir, "cap_reservoir")
    else
        push!(vb, gencapacity(cap_reservoir, "level", s, name * " " * elec.name;
            mincap=mincap_reservoir, maxcap=maxcap_reservoir, argname="cap_reservoir"))
    end

    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)
    
    # exogenously force production
    # _output = balance(c, :output, energy, collapse=false).data
    # _profile = gettimeseries(s, zone, "fixed_reservoir_output")
    # @constraint(sim(c).model, _output .== _profile)

    connect!(s, c, elec)
    for t in ("generation", "storage", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end

"""
    makebatterystorage(name::String, elec::Node, s::Snapshot;
        tech::String=name, tech_column::String=tech,
        cap=nothing, mincap=nothing, maxcap=nothing, simplified=false,
        gridlosses=0.,
        eff::Union{Nothing,Real}=nothing, duration::Union{Nothing,Real}=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
    )

Build, connect and return a battery storage component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `tech_column`: technology column name in the `storage` tech data sheet;
    defaults to `tech`.
  * `elec`: electricity node to connect the component to.
  * `s`: snapshot to register the component in.

  * `cap`: Charging/input capacity in MW. A number fixes capacity, a JuMP
    `VariableRef` or `AffExpr` reuses that expression, `nothing` creates a
    capacity decision, and an extracted `Snapshot` inherits the capacity of
    `"<name> <node name>"` in it.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `simplified`: Passed to `BasicStorage(..., simplified=...)`.

  * `gridlosses`: Proportional charging-loss fraction (`0 <= gridlosses < 1`).

  * `eff`: Dimensionless round-trip storage efficiency.
  * `duration`: Storage duration in hours (`duration > 0`); required in
    `:arguments` mode and otherwise read from the workbook when `nothing`.

  * `overnight_cost`: Overnight CAPEX in currency/kW of charging capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of charging capacity.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.
  * `connection_cost`: Connection cost as a fraction of annualized investment.
  * `om_var_cost`: Variable O&M in currency/MWh charged.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makebatterystorage(name::String, elec::Node, s::Snapshot;
    tech::String=name, tech_column::String=tech,
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    simplified::Bool=false, gridlosses::Real=0.,

    # technical overrides
    eff::Union{Nothing,Real}=nothing, duration::Union{Nothing,Real}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "storage") : overnight_cost
        _eff = isnothing(eff) ? gettechparam(s, tech_column, "roundtrip_eff", "storage") : eff
        _dur = isnothing(duration) ? gettechparam(s, tech_column, "duration", "storage") : duration
        _conn = isnothing(connection_cost) ? gettechparam(s, tech_column, "connection_cost", "storage") : connection_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "storage") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "storage") : decommissioning
        _vom = isnothing(om_var_cost) ? gettechparam(s, tech_column, "om_var_cost", "storage") : om_var_cost
    else
        _oc_raw = something(overnight_cost, 0.0)
        _eff = something(eff, 1.0)
        _dur = isnothing(duration) ? throw(ArgumentError(
            "`duration` must be supplied when tech_mode=:arguments",
        )) : duration
        _conn = something(connection_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _vom = something(om_var_cost, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, tech_column, "lifetime", "storage") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, tech_column, "construction_profile", "storage") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, tech_column, "decommissioning_profile", "storage") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        gridlosses=gridlosses, overnight_cost=_oc_raw, lifetime=_lt_raw, efficiency=_eff,
        duration=_dur, connection_cost=_conn, om_fixed_cost=_fom, decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _gridlosses = Float64(gridlosses)
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discountrate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discountrate(s), _dcp)
    end
    _eff = Float64(_eff)
    m = BasicStorage(elec.carrier, eff_i=_eff, simplified=simplified)
    vb = []
    
    push!(vb, Duration(_dur))
    push!(vb, gencapacity(cap, "input", s, name * " " * elec.name; mincap=mincap, maxcap=maxcap))
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:connection, "input", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "input", energy, _decom_cost))
    push!(vb, VariableCost(:vom, "input", energy, _vom))

    if !iszero(_gridlosses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _gridlosses))
    end

    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)

    for t in ("electricity", "storage", "generation")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)

    return c
end

"""
    makehydrogenstorage(name::String, h2::Node, s::Snapshot;
        tech::String=name, tech_column::String=tech,
        cap=nothing, mincap=nothing, maxcap=nothing,
        eff::Union{Nothing,Real}=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a hydrogen storage component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `tech_column`: technology column name in the `storage` tech data sheet;
    defaults to `tech`.
  * `h2`: hydrogen node to connect the component to.
  * `s`: snapshot to register the component in.

  * `cap`: Storage level capacity in MWh. A number fixes capacity, a JuMP `VariableRef`
    or `AffExpr` reuses that expression, `nothing` creates a capacity decision,
    and an extracted `Snapshot` inherits the capacity of `"<name> <node name>"` in it.
  * `mincap`: Lower capacity bound in MWh;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MWh;
    checked as an assertion against a fixed or inherited one.

  * `eff`: Dimensionless round-trip storage efficiency. If `nothing`, read it
    from the workbook in `:excel` mode and use one in `:arguments` mode.

  * `overnight_cost`: Overnight CAPEX in currency/kWh of storage capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kWh/year of storage capacity.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makehydrogenstorage(name::String, h2::Node, s::Snapshot;
    tech::String=name, tech_column::String=tech,
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,

    # technical overrides
    eff::Union{Nothing,Real}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _eff = isnothing(eff) ? gettechparam(s, tech_column, "roundtrip_eff", "storage") : eff
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "storage") : overnight_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "storage") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "storage") : decommissioning
    else
        _eff = something(eff, 1.0)
        _oc_raw = something(overnight_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _decom = something(decommissioning, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, tech_column, "lifetime", "storage") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, tech_column, "construction_profile", "storage") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, tech_column, "decommissioning_profile", "storage") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        om_fixed_cost=_fom, decommissioning=_decom,
    )
    validate_component_input(inputs)

    _eff = Float64(_eff)
    m = BasicStorage(h2.carrier, eff_i=_eff, simplified=true) # always simplified for this medium or long term storage archetype
    vb = []
    _oc = _oc_raw * 1000.0
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc, discountrate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc, _decom, Int(_lt_raw), discountrate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "level", energy, _inv))
    push!(vb, FixedCost(:fom, "level", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "level", energy, _decom_cost))

    push!(vb, gencapacity(cap, "level", s, name * " " * h2.name; mincap=mincap, maxcap=maxcap))
    # push!(vb, Duration(4)) # TYNDP methodology 9.6.4: fill in 4 hours # removed for large storage (no meaning, no impact except negative on performance)
    c = Component(name * " " * h2.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, h2.name)
    for t in ("hydrogen", "storage")
        tag!(c, :function, t)
    end
    connect!(s, c, h2)
    return c
end
