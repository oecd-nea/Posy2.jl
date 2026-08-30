"""
Generate storage components.
"""

"""
    makehydroreservoir(name::String, zone::String, elec::Node, s::Snapshot;
        tech::String=name, tech_column::String=tech,
        discharge_cap, charge_cap, intake, energy_cap=Inf, spillage=false,
        weather_year=nothing, grid_losses=0., simplified=false,
        intake_profile=nothing,
        roundtrip_eff::Union{Nothing,Real}=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing,
        construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a hydro reservoir component.

This builder does not cover endogenous capacity expansion of the reservoir.
`discharge_cap`, `charge_cap` and `energy_cap` are exogenous: unlike the other
builders they accept neither `nothing` nor a JuMP expression, and so are never
capacity decisions. A model-sized reservoir would be built free of charge,
because CAPEX and fixed O&M are applied to discharging capacity alone. Costs
still apply to the fixed capacities, so an existing fleet reports its
annualized cost.

If you need an expandable reservoir, please write a dedicated component builder
for it. It needs a cost basis for each expanded dimension, which the shared
`storage` technology sheet does not carry.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `tech_column`: technology column name in the `storage` tech data sheet;
    defaults to `tech`.
  * `zone`: Zone used for reservoir intake time series lookup.
  * `elec`: electricity node to connect the component to.
  * `s`: snapshot to register the component in.
  * `discharge_cap`: Discharging capacity in MW. A number fixes it, and an
    extracted `Snapshot` inherits the capacity of `"<name> <node name>"` in it.
  * `charge_cap`: Charging capacity in MW with the same choices. The `input`
    port is always created; numeric `0` gives it a zero capacity, so a
    turbine-only reservoir still reports a charging flow of zero.
  * `intake`: Total natural intake in MWh over the modeled profile (normally one
    year). `0` disables natural intake.

  * `energy_cap`: Storage level capacity in MWh, with the same choices as
    `discharge_cap`, plus `Inf` (the default) which leaves the level
    unlimited by adding no level capacity behavior.

  * `spillage`: Add an unconnected, unlimited `spill` output that lets the
    reservoir release stored energy without generating. It defaults to `false`,
    which forces all natural intake to eventually become generation.

  * `weather_year`: Year suffix used to select the intake series stored in
    `reservoir_inflow_<year>`. Required when `intake_profile` is read from the
    time-series workbook; unused when a profile is supplied explicitly or
    natural intake is disabled.
  * `grid_losses`: Proportional charging-loss fraction (`0 <= grid_losses < 1`).
  * `simplified`: Passed to `LazyStorage(..., simplified=...)`.
  * `intake_profile`: Dimensionless hourly natural-intake shape or scalar,
    nonnegative with a strictly positive sum. It is normalized to sum to one
    before `intake` is applied. If `nothing`, read `zone` from
    `reservoir_inflow_<weather_year>`.

  * `roundtrip_eff`: Dimensionless round-trip charging efficiency.

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
    discharge_cap::Union{Real,Snapshot},
    charge_cap::Union{Real,Snapshot},
    intake::Real,
    energy_cap::Union{Real,Snapshot}=Inf,

    # storage operation controls
    spillage::Bool=false,
    weather_year::Union{Nothing,Integer}=nothing, grid_losses::Real=0.,
    simplified::Bool=false,
    intake_profile=nothing,

    # technical overrides
    roundtrip_eff::Union{Nothing,Real}=nothing,

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    om_var_cost::Union{Nothing,Real}=nothing, decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing,
    construction_profile=nothing, decommissioning_profile=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _eff = isnothing(roundtrip_eff) ? gettechparam(s, tech_column, "roundtrip_eff", "storage") : roundtrip_eff
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "storage") : overnight_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "storage") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "storage") : decommissioning
        _vom = isnothing(om_var_cost) ? gettechparam(s, tech_column, "om_var_cost", "storage") : om_var_cost
    else
        _eff = something(roundtrip_eff, 1.0)
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
        grid_losses=grid_losses, efficiency=_eff, overnight_cost=_oc_raw, lifetime=_lt_raw,
        om_fixed_cost=_fom, decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _grid_losses = Float64(grid_losses)
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
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discount_rate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discount_rate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "output", energy, _decom_cost))
    push!(vb, VariableCost(:vom, "output", energy, _vom))

    @argcheck isfinite(intake) && intake >= 0 "makehydroreservoir `intake` must be finite and non-negative."
    intake_series = if iszero(intake)
        zeros(Nosy.nhours(sim(s)))
    else
        if isnothing(intake_profile) && timeseries_mode(s) === :excel && isnothing(weather_year)
            throw(ArgumentError(
                "`weather_year` must be supplied when `intake_profile` is read from the time-series workbook",
            ))
        end
        profile_sheet = isnothing(weather_year) ? nothing : "reservoir_inflow_$weather_year"
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
    
    push!(vb, gencapacity(discharge_cap, "output", s, name * " " * elec.name; argname="discharge_cap"))

    # the charging branch always exists, at zero capacity when charging is disabled
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, gencapacity(charge_cap, "input", s, name * " " * elec.name; argname="charge_cap"))
    !iszero(_grid_losses) && push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _grid_losses))

    # `Inf` leaves the level unlimited by adding no level capacity behavior
    if !(energy_cap isa Real && energy_cap == Inf)
        push!(vb, gencapacity(energy_cap, "level", s, name * " " * elec.name; argname="energy_cap"))
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
        power_cap=nothing, power_mincap=nothing, power_maxcap=nothing,
        simplified=false, grid_losses=0.,
        roundtrip_eff::Union{Nothing,Real}=nothing, duration::Union{Nothing,Real}=nothing,
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

  * `power_cap`: Power capacity in MW. It bounds charging and discharging
    alike, and the stored level at `power_cap * duration`. A number fixes
    capacity, a JuMP `VariableRef` or `AffExpr` reuses that expression,
    `nothing` creates a capacity decision, and an extracted `Snapshot` inherits
    the capacity of `"<name> <node name>"` in it.
  * `power_mincap`: Lower power-capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `power_maxcap`: Upper power-capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `simplified`: Passed to `BasicStorage(..., simplified=...)`.

  * `grid_losses`: Proportional charging-loss fraction (`0 <= grid_losses < 1`).

  * `roundtrip_eff`: Dimensionless round-trip storage efficiency.
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
    power_cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    power_mincap::Union{Nothing,Real}=nothing, power_maxcap::Union{Nothing,Real}=nothing,
    simplified::Bool=false, grid_losses::Real=0.,

    # technical overrides
    roundtrip_eff::Union{Nothing,Real}=nothing, duration::Union{Nothing,Real}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "storage") : overnight_cost
        _eff = isnothing(roundtrip_eff) ? gettechparam(s, tech_column, "roundtrip_eff", "storage") : roundtrip_eff
        _dur = isnothing(duration) ? gettechparam(s, tech_column, "duration", "storage") : duration
        _conn = isnothing(connection_cost) ? gettechparam(s, tech_column, "connection_cost", "storage") : connection_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "storage") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "storage") : decommissioning
        _vom = isnothing(om_var_cost) ? gettechparam(s, tech_column, "om_var_cost", "storage") : om_var_cost
    else
        _oc_raw = something(overnight_cost, 0.0)
        _eff = something(roundtrip_eff, 1.0)
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
        grid_losses=grid_losses, overnight_cost=_oc_raw, lifetime=_lt_raw, efficiency=_eff,
        duration=_dur, connection_cost=_conn, om_fixed_cost=_fom, decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

    _grid_losses = Float64(grid_losses)
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discount_rate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discount_rate(s), _dcp)
    end
    _eff = Float64(_eff)
    m = BasicStorage(elec.carrier, eff_i=_eff, simplified=simplified)
    vb = []
    
    push!(vb, Duration(_dur))
    push!(vb, gencapacity(power_cap, "input", s, name * " " * elec.name;
        mincap=power_mincap, maxcap=power_maxcap, argname="power_cap"))
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:connection, "input", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "input", energy, _decom_cost))
    push!(vb, VariableCost(:vom, "input", energy, _vom))

    if !iszero(_grid_losses)
        push!(vb, LinkedJointFlow("grid losses", elec.carrier, :input, "input", x->x[1] * _grid_losses))
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
        energy_cap=nothing, energy_mincap=nothing, energy_maxcap=nothing,
        roundtrip_eff::Union{Nothing,Real}=nothing,
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

  * `energy_cap`: Stored-energy capacity in MWh. Charging and discharging power
    are left unlimited. A number fixes capacity, a JuMP `VariableRef` or
    `AffExpr` reuses that expression, `nothing` creates a capacity decision, and
    an extracted `Snapshot` inherits the capacity of `"<name> <node name>"` in it.
  * `energy_mincap`: Lower energy-capacity bound in MWh;
    checked as an assertion against a fixed or inherited one.
  * `energy_maxcap`: Upper energy-capacity bound in MWh;
    checked as an assertion against a fixed or inherited one.

  * `roundtrip_eff`: Dimensionless round-trip storage efficiency. If `nothing`, read it
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
    energy_cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    energy_mincap::Union{Nothing,Real}=nothing, energy_maxcap::Union{Nothing,Real}=nothing,

    # technical overrides
    roundtrip_eff::Union{Nothing,Real}=nothing,

    # economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
)
    excel = tech_mode(s) === :excel
    if excel
        _eff = isnothing(roundtrip_eff) ? gettechparam(s, tech_column, "roundtrip_eff", "storage") : roundtrip_eff
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, tech_column, "overnight_cost", "storage") : overnight_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, tech_column, "om_fixed_cost", "storage") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, tech_column, "decommissioning", "storage") : decommissioning
    else
        _eff = something(roundtrip_eff, 1.0)
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
    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc, discount_rate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc, _decom, Int(_lt_raw), discount_rate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "level", energy, _inv))
    push!(vb, FixedCost(:fom, "level", energy, _fom * 1000.))
    push!(vb, FixedCost(:decommissioning, "level", energy, _decom_cost))

    push!(vb, gencapacity(energy_cap, "level", s, name * " " * h2.name;
        mincap=energy_mincap, maxcap=energy_maxcap, argname="energy_cap"))
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
