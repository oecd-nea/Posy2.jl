"""
Generate generation-side components.
"""

using ArgCheck: @argcheck

"""
    makedispatchable(name::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
        tech::String=name,
        cap=nothing, mincap=nothing, maxcap=nothing, capacitymultiplier=nothing,
        integeruc=false, uc=false, fuelnode=nothing,
        co2price=co2_price(s),
        overnight_cost, om_fixed_cost, decommissioning, lifetime,
        construction_profile, decommissioning_profile, connection_cost,
        om_var_cost, fuel_cost, no_load_cost, startup_cost, co2_emission,
        efficiency, unit_size, ramp_up, ramp_down, min_power, min_uptime,
        min_downtime, startup_duration, shutdown_duration,
    )

Build, connect and return a dispatchable component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `techkey`: technology column name in the `dispatchable` tech data sheet.
  * `elec`: Electricity node connected to component output flow.
  * `co2`: CO2 node connected only when `co2_emission != 0`.
  * `s`: Target snapshot where the component and behaviors are registered.

  * `cap`: Output capacity in MW. A number fixes capacity, a
    JuMP `VariableRef` or `AffExpr` reuses that expression, `nothing` creates a
    capacity decision, and an extracted `Snapshot` inherits the capacity of
    `"<name> <node name>"` in it. Numeric `0` builds a zero-capacity component.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `capacitymultiplier`: Dimensionless time-varying multiplier on output capacity.

  * `integeruc`: If `true`, newly constructed UC commitment variables are
    integer; used only when `uc=true`.
  * `uc`: Enables UC constraints and UC linked costs (`no_load_cost`, `startup_cost`).
    An extracted `Snapshot` instead replays the commitment schedule already
    solved for the matching component, and then requires a fixed `cap`.
  * `fuelnode`: If provided, fuel is modeled as an input flow linked by efficiency. If `nothing`, fuel is modeled as a variable cost on output energy (`fuel_cost`).

  * `co2price`: Carbon price in currency/tCO2, used only when
    `co2_emission != 0`.

  * `overnight_cost`: Overnight CAPEX in currency/kW of output capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of output capacity.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.
  * `connection_cost`: Connection cost as a fraction of annualized investment.
  * `om_var_cost`: Variable O&M in currency/MWh of output.
  * `fuel_cost`: Fuel cost in currency/MWh of output, used only without `fuelnode`.
  * `no_load_cost`: No-load cost in currency/committed-unit/hour, used with UC.
  * `startup_cost`: Startup cost in currency/unit-start, used with UC.
  * `co2_emission`: Emission factor in kgCO2/MWh of output; converted to tCO2.
  * `efficiency`: Output per unit of fuel input (dimensionless when both carriers
    use MWh), used only with `fuelnode`.
  * `unit_size`: Generating-unit size in MW. `0` disables unit sizing; a positive
    value is required with UC.
  * `ramp_up`, `ramp_down`: Maximum ramp fractions of unit capacity per hour;
    nonzero values require a positive `unit_size`.
  * `min_power`: Minimum committed output as a fraction of unit capacity, used
    only when `uc=true`.
  * `min_uptime`, `min_downtime`, `startup_duration`, `shutdown_duration`:
    Durations in hours, used only when `uc=true`.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makedispatchable(name::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
    tech::String=name,
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    capacitymultiplier=nothing,

    # unit commitment / operation
    integeruc=false, uc::Union{Bool,Snapshot}=false, fuelnode=nothing,

    co2price::Real=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing,
    construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
    fuel_cost::Union{Nothing,Real}=nothing, no_load_cost::Union{Nothing,Real}=nothing,
    startup_cost::Union{Nothing,Real}=nothing, co2_emission::Union{Nothing,Real}=nothing,
    efficiency::Union{Nothing,Real}=nothing, unit_size::Union{Nothing,Real}=nothing,
    ramp_up::Union{Nothing,Real}=nothing, ramp_down::Union{Nothing,Real}=nothing,
    min_power::Union{Nothing,Real}=nothing, min_uptime::Union{Nothing,Real}=nothing,
    min_downtime::Union{Nothing,Real}=nothing,
    startup_duration::Union{Nothing,Real}=nothing, shutdown_duration::Union{Nothing,Real}=nothing,
)
    _checkucsource(uc, cap)
    excel = tech_mode(s) === :excel
    if excel
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, techkey, "overnight_cost", "dispatchable") : overnight_cost
        _conn = isnothing(connection_cost) ? gettechparam(s, techkey, "connection_cost", "dispatchable") : connection_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, techkey, "om_fixed_cost", "dispatchable") : om_fixed_cost
        _vom = isnothing(om_var_cost) ? gettechparam(s, techkey, "om_var_cost", "dispatchable") : om_var_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, techkey, "decommissioning", "dispatchable") : decommissioning
        _co2_em = isnothing(co2_emission) ? gettechparam(s, techkey, "co2_emission", "dispatchable") : co2_emission
        _usize_raw = isnothing(unit_size) ? gettechparam(s, techkey, "unit_size", "dispatchable") : unit_size
        _fuel = isnothing(fuelnode) ? (isnothing(fuel_cost) ? gettechparam(s, techkey, "fuel_cost", "dispatchable") : fuel_cost) : nothing
        _eff = isnothing(fuelnode) ? nothing : (isnothing(efficiency) ? gettechparam(s, techkey, "efficiency", "dispatchable") : efficiency)
    else
        _oc_raw = something(overnight_cost, 0.0)
        _conn = something(connection_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _vom = something(om_var_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _co2_em = something(co2_emission, 0.0)
        _usize_raw = unit_size
        _fuel = isnothing(fuelnode) ? something(fuel_cost, 0.0) : nothing
        _eff = isnothing(fuelnode) ? nothing : something(efficiency, 1.0)
    end
    inputs = component_input(
        overnight_cost=_oc_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, decommissioning=_decom, co2_emission=_co2_em, unit_size=_usize_raw,
        fuel_cost=_fuel, efficiency=_eff,
    )
    validate_component_input(inputs)

    m = DispatchableSource(elec.carrier)
    vb = []
    _oc = _oc_raw * 1000.
    _lt = nothing
    _cp = nothing
    _inv = 0.0
    if !iszero(_oc_raw)
        _lt_raw = if isnothing(lifetime)
            excel ? gettechparam(s, techkey, "lifetime", "dispatchable") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero",
            ))
        else
            lifetime
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, techkey, "construction_profile", "dispatchable") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero",
            ))
        else
            construction_profile
        end
        validate_component_input(component_input(lifetime=_lt_raw))
        _lt = Int(_lt_raw)
        _inv = eac(_oc, discountrate(s), _lt, _cp)
    end
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    
    # capacity multiplier
    if !isnothing(capacitymultiplier)
        push!(vb, CapacityMultiplier("output", capacitymultiplier))
    end

    # decommissioning costs are inactive unless both inputs are non-zero
    _decom_cost = 0.0
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, techkey, "decommissioning_profile", "dispatchable") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero",
            ))
        else
            decommissioning_profile
        end
        _decom_cost = decom_cost(_oc, _decom, _lt, discountrate(s), _dcp)
    end
    push!(vb, FixedCost(:decommissioning, "output", energy, _decom_cost))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    if isnothing(_usize_raw) || iszero(_usize_raw)
        _usize = nothing
    else
        @argcheck _usize_raw > 0 "unit_size must be > 0 when non-zero."
        _usize = _usize_raw
    end
    _mincap = mincap
    _maxcap = maxcap
    if _ucenabled(uc) && integeruc && !isnothing(_usize) && isnothing(cap)
        if !isnothing(_mincap)
            _mincap = ceil(_mincap / _usize) * _usize
        end
        if !isnothing(_maxcap) && isfinite(_maxcap)
            _maxcap = floor(_maxcap / _usize) * _usize
        end
    end
    push!(vb, gencapacity(cap, "output", s, name * " " * elec.name;
        mincap=_mincap, maxcap=_maxcap, unitsize=_usize))

    # fuel node management
    if isnothing(fuelnode)
        push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    else
        _eff = Float64(_eff)
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x[1] / _eff))
    end

    if _ucenabled(uc)
        isnothing(_usize) && throw(ArgumentError(
            "`unit_size` must be supplied as a positive number when uc=true",
        ))
        if uc isa Snapshot
            _pushinheriteduc!(vb, uc, name * " " * elec.name, "output")
        else
            _min_power = isnothing(min_power) ? (excel ? gettechparam(s, techkey, "min_power", "dispatchable") : 0.0) : min_power
            _min_uptime = isnothing(min_uptime) ? (excel ? gettechparam(s, techkey, "min_uptime", "dispatchable") : 0.0) : min_uptime
            _min_downtime = isnothing(min_downtime) ? (excel ? gettechparam(s, techkey, "min_downtime", "dispatchable") : 0.0) : min_downtime
            _startup_dur = isnothing(startup_duration) ? (excel ? gettechparam(s, techkey, "startup_duration", "dispatchable") : 0.0) : startup_duration
            _shutdown_dur = isnothing(shutdown_duration) ? (excel ? gettechparam(s, techkey, "shutdown_duration", "dispatchable") : 0.0) : shutdown_duration
            @argcheck _min_power isa Real "min_power must be Real."
            @argcheck _min_uptime isa Real "min_uptime must be Real."
            @argcheck _min_downtime isa Real "min_downtime must be Real."
            @argcheck _startup_dur isa Real "startup_duration must be Real."
            @argcheck _shutdown_dur isa Real "shutdown_duration must be Real."
            push!(vb, UnitCommitment("output", 
                _min_power, 
                uptime=_min_uptime, 
                downtime=_min_downtime, 
                startup=_startup_dur, 
                shutdown=_shutdown_dur, 
                integer=integeruc)
            )
        end
        _noload = isnothing(no_load_cost) ? (excel ? gettechparam(s, techkey, "no_load_cost", "dispatchable") : 0.0) : no_load_cost
        _startup = isnothing(startup_cost) ? (excel ? gettechparam(s, techkey, "startup_cost", "dispatchable") : 0.0) : startup_cost
        @argcheck _noload isa Real "no_load_cost must be Real."
        @argcheck _startup isa Real "startup_cost must be Real."
        push!(vb, NoLoadCost(:noload, "output", _noload))
        push!(vb, StartupCost(:startup, "output", _startup))
    end

    if !isnothing(_usize)
        _ru = isnothing(ramp_up) && excel ? gettechparam(s, techkey, "ramp_up", "dispatchable") : ramp_up
        _rd = isnothing(ramp_down) && excel ? gettechparam(s, techkey, "ramp_down", "dispatchable") : ramp_down
        @argcheck isnothing(_ru) || _ru isa Real "ramp_up must be Real or nothing."
        @argcheck isnothing(_rd) || _rd isa Real "ramp_down must be Real or nothing."
        @argcheck isnothing(_ru) || _ru >= 0 "ramp_up must be non negative."
        @argcheck isnothing(_rd) || _rd >= 0 "ramp_down must be non negative."
        if !isnothing(_ru) && !iszero(_ru)
            push!(vb, Ramping("output", :up, _ru * _usize, energy))
        end
        if !isnothing(_rd) && !iszero(_rd)
            push!(vb, Ramping("output", :down, _rd * _usize, energy))
        end
    else
        for (param, value) in (("ramp_up", ramp_up), ("ramp_down", ramp_down))
            if !isnothing(value)
                @argcheck value isa Real "$param must be Real or nothing."
                @argcheck value >= 0 "$param must be non negative."
                iszero(value) || throw(ArgumentError(
                    "`unit_size` must be supplied as a positive number when $param is non-zero",
                ))
            end
        end
    end

    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
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
    makenuclear(name::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
        tech::String=name,
        cap=nothing, mincap=nothing, maxcap=nothing, integercap=false, warmstart=nothing,
        uc=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,
        refuel::Bool=true, refuel_duration::Union{Nothing,Real}=nothing,
        refuelmask::Union{Nothing,Real}=nothing, refuel_fraction_per_year::Union{Nothing,Real}=nothing,
        fuelnode=nothing, co2price=co2_price(s),
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing, fuel_cost::Union{Nothing,Real}=nothing,
        waste_cost::Union{Nothing,Real}=nothing, no_load_cost::Union{Nothing,Real}=nothing, startup_cost::Union{Nothing,Real}=nothing,
        co2_emission::Union{Nothing,Real}=nothing, efficiency::Union{Nothing,Real}=nothing, unit_size::Union{Nothing,Real}=nothing,
        ramp_up::Union{Nothing,Real}=nothing, ramp_down::Union{Nothing,Real}=nothing,
        min_power::Union{Nothing,Real}=nothing, min_uptime::Union{Nothing,Real}=nothing, min_downtime::Union{Nothing,Real}=nothing,
        startup_duration::Union{Nothing,Real}=nothing, shutdown_duration::Union{Nothing,Real}=nothing,
    )

Build, connect and return a nuclear reactor component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `techkey`: technology column name in the `dispatchable` tech data sheet.
  * `elec`: electricity node to connect the component to.
  * `co2`: CO2 node connected when `co2_emission` is non zero.
  * `s`: snapshot to register the component in.

  * `cap`: Output capacity in MW. A number fixes capacity, a JuMP `VariableRef` or
    `AffExpr` reuses that expression, `nothing` creates a capacity decision, and
    an extracted `Snapshot` inherits the capacity of `"<name> <node name>"` in it.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `integercap`: Integer flag for variable capacity; ignored for fixed or
    inherited capacity.
  * `warmstart`: Variable-capacity warm start in MW; ignored for fixed or
    inherited capacity.

  * `uc`: Enables UC constraints and UC linked costs. An extracted `Snapshot`
    instead replays the commitment schedule already solved for the matching
    component and requires a fixed `cap`. Fresh refuelling constraints are built
    only when `uc=true`; with `uc=false` they are ignored, and a replayed schedule
    retains its solved refuelling decisions.
  * `integeruc`: Integer UC commitment variables, used only when `uc=true`.
  * `startupmask`: Startup availability mask, used only when `uc=true`.
  * `shutdownmask`: Shutdown availability mask, used only when `uc=true`.

  * `refuel`: Enables planned refuelling constraints. Set to `false` to disable refuelling regardless of the other refuelling arguments.
  * `refuel_duration`: Planned refuelling outage in hours. A positive value
    enables refuelling constraints when `refuel_fraction_per_year > 0`. If
    `nothing`, use the workbook value in `:excel` mode and zero in `:arguments`
    mode.
  * `refuelmask`: Positive integer interval in model time steps between allowed
    refuelling windows; not read from the workbook.
  * `refuel_fraction_per_year`: Minimum refuelling events per unit/year. If
    `nothing`, use the workbook value in `:excel` mode and zero in `:arguments`
    mode.

  * `fuelnode`: If provided, fuel is represented as linked input flow using `efficiency`. If `nothing`, `fuel_cost` is applied as output variable cost.
  * `co2price`: Carbon price in currency/tCO2, used only when
    `co2_emission != 0`.

  * `overnight_cost`: Overnight CAPEX in currency/kW of output capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of output capacity.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.
  * `connection_cost`: Connection cost as a fraction of annualized investment.
  * `om_var_cost`, `fuel_cost`, `waste_cost`: Costs in currency/MWh of output;
    `fuel_cost` is used directly only without `fuelnode`.
  * `no_load_cost`: No-load cost in currency/committed-unit/hour, used with UC.
  * `startup_cost`: Startup cost in currency/unit-start, used with UC.
  * `co2_emission`: Emission factor in kgCO2/MWh of output; converted to tCO2.
  * `efficiency`: Output per unit of fuel input (dimensionless when both carriers
    use MWh), used only with `fuelnode`.
  * `unit_size`: Reactor-unit size in MW. `0` disables unit sizing; a positive
    value is required with UC.
  * `ramp_up`, `ramp_down`: Maximum ramp fractions of unit capacity per hour;
    nonzero values require a positive `unit_size`.
  * `min_power`: Minimum committed output as a fraction of unit capacity, used
    only when `uc=true`.
  * `min_uptime`, `min_downtime`, `startup_duration`, `shutdown_duration`:
    Durations in hours, used only when `uc=true`.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makenuclear(name::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
    tech::String=name,
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    integercap=false, warmstart::Union{Nothing,Real}=nothing,

    # unit commitment / operation
    uc::Union{Bool,Snapshot}=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,

    # refuelling controls
    refuel::Bool=true, refuel_duration::Union{Nothing,Real}=nothing,
    refuelmask::Union{Nothing,Real}=nothing, refuel_fraction_per_year::Union{Nothing,Real}=nothing,

    # external nodes / prices
    fuelnode=nothing, co2price::Real=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing, fuel_cost::Union{Nothing,Real}=nothing,
    waste_cost::Union{Nothing,Real}=nothing, no_load_cost::Union{Nothing,Real}=nothing,
    startup_cost::Union{Nothing,Real}=nothing, co2_emission::Union{Nothing,Real}=nothing, efficiency::Union{Nothing,Real}=nothing,
    unit_size::Union{Nothing,Real}=nothing,
    ramp_up::Union{Nothing,Real}=nothing, ramp_down::Union{Nothing,Real}=nothing,
    min_power::Union{Nothing,Real}=nothing,
    min_uptime::Union{Nothing,Real}=nothing, min_downtime::Union{Nothing,Real}=nothing,
    startup_duration::Union{Nothing,Real}=nothing, shutdown_duration::Union{Nothing,Real}=nothing,
)
    _checkucsource(uc, cap)
    m = DispatchableSource(elec.carrier)
    vb = []
    excel = tech_mode(s) === :excel
    if excel
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, techkey, "overnight_cost", "dispatchable") : overnight_cost
        _conn = isnothing(connection_cost) ? gettechparam(s, techkey, "connection_cost", "dispatchable") : connection_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, techkey, "om_fixed_cost", "dispatchable") : om_fixed_cost
        _vom = isnothing(om_var_cost) ? gettechparam(s, techkey, "om_var_cost", "dispatchable") : om_var_cost
        _waste = isnothing(waste_cost) ? gettechparam(s, techkey, "waste_cost", "dispatchable") : waste_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, techkey, "decommissioning", "dispatchable") : decommissioning
        _co2_em = isnothing(co2_emission) ? gettechparam(s, techkey, "co2_emission", "dispatchable") : co2_emission
        _usize_raw = isnothing(unit_size) ? gettechparam(s, techkey, "unit_size", "dispatchable") : unit_size
        _fuel = isnothing(fuelnode) ? (isnothing(fuel_cost) ? gettechparam(s, techkey, "fuel_cost", "dispatchable") : fuel_cost) : nothing
        _eff = isnothing(fuelnode) ? nothing : (isnothing(efficiency) ? gettechparam(s, techkey, "efficiency", "dispatchable") : efficiency)
    else
        _oc_raw = something(overnight_cost, 0.0)
        _conn = something(connection_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _vom = something(om_var_cost, 0.0)
        _waste = something(waste_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _co2_em = something(co2_emission, 0.0)
        _usize_raw = unit_size
        _fuel = isnothing(fuelnode) ? something(fuel_cost, 0.0) : nothing
        _eff = isnothing(fuelnode) ? nothing : something(efficiency, 1.0)
    end

    _lt_raw = lifetime
    _inv = 0.0
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, techkey, "lifetime", "dispatchable") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, techkey, "construction_profile", "dispatchable") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, techkey, "decommissioning_profile", "dispatchable") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, waste_cost=_waste, decommissioning=_decom, co2_emission=_co2_em,
        unit_size=_usize_raw, fuel_cost=_fuel, efficiency=_eff,
    )
    validate_component_input(inputs)

    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discountrate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discountrate(s), _dcp)
    end

    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    push!(vb, VariableCost(:waste, "output", energy, _waste))
    push!(vb, FixedCost(:decommissioning, "output", energy, _decom_cost))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    if isnothing(_usize_raw) || iszero(_usize_raw)
        _usize = nothing
    else
        @argcheck _usize_raw > 0 "unit_size must be > 0 when non-zero."
        _usize = _usize_raw
    end
    if (_ucenabled(uc) || (integercap && isnothing(cap))) && isnothing(_usize)
        throw(ArgumentError("`unit_size` must be positive when unit commitment or integer capacity expansion is enabled"))
    end
    push!(vb, gencapacity(cap, "output", s, name * " " * elec.name;
        mincap=mincap, maxcap=maxcap, unitsize=_usize, integer=integercap, warmstart=warmstart))

    # fuel node management
    # fuel cost only used if fuel node is nothing
    if isnothing(fuelnode)
        push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    else
        _eff = Float64(_eff)
        push!(vb, LinkedJointFlow("fuel", fuelnode.carrier, :input, "output", x->x[1] / _eff))
    end

    # special case: cycling constraints for nuclear
    _refuel = false
    if refuel && !_ucenabled(uc) && (!isnothing(refuel_duration) || !isnothing(refuelmask) || !isnothing(refuel_fraction_per_year))
        @warn "Because uc=false for nuclear component, refuelling is not modeled." component=name techkey=techkey
    end
    if refuel && uc isa Snapshot && (!isnothing(refuel_duration) || !isnothing(refuelmask) || !isnothing(refuel_fraction_per_year))
        @warn "Because uc replays a solved schedule for nuclear component, refuelling follows that schedule and refuelling arguments are ignored." component=name techkey=techkey
    end
    # refuelling constraints are built from fresh arguments, never over a replayed schedule
    if refuel && uc === true
        _refuel_fraction = if isnothing(refuel_fraction_per_year)
            excel ? gettechparam(s, techkey, "refuel_fraction_per_year", "dispatchable") : 0.0
        else
            refuel_fraction_per_year
        end
        @argcheck _refuel_fraction isa Real "refuel_fraction_per_year must be Real."
        @argcheck _refuel_fraction >= 0 "refuel_fraction_per_year must be >= 0."
        if _refuel_fraction > 0
            _refuel_duration = if isnothing(refuel_duration)
                excel ? gettechparam(s, techkey, "refuel_duration", "dispatchable") : 0.0
            else
                refuel_duration
            end
            @argcheck _refuel_duration isa Real "refuel_duration must be Real."
            @argcheck _refuel_duration >= 0 "refuel_duration must be >= 0."
            _refuel = (_refuel_fraction > 0) && (_refuel_duration > 0)
            if _refuel
                @argcheck !isnothing(refuelmask) "refuelmask must be provided when refuelling is enabled."
                _refuel_mask_raw = refuelmask
                @argcheck _refuel_mask_raw isa Real "refuelmask must be Real."
                @argcheck _refuel_mask_raw > 0 "refuelmask must be > 0 when refuelling is enabled."
                @argcheck isinteger(_refuel_mask_raw) "refuelmask must be integer-valued."
                _refuel_mask = Int(_refuel_mask_raw)
            end
        end
    end
    if _ucenabled(uc)
        _noload = isnothing(no_load_cost) ? (excel ? gettechparam(s, techkey, "no_load_cost", "dispatchable") : 0.0) : no_load_cost
        _startup = isnothing(startup_cost) ? (excel ? gettechparam(s, techkey, "startup_cost", "dispatchable") : 0.0) : startup_cost
        @argcheck _noload isa Real "no_load_cost must be Real."
        @argcheck _startup isa Real "startup_cost must be Real."
        push!(vb, NoLoadCost(:noload, "output", _noload))
        push!(vb, StartupCost(:startup, "output", _startup))
        if uc isa Snapshot
            _pushinheriteduc!(vb, uc, name * " " * elec.name, "output")
        else
            _min_power = isnothing(min_power) ? (excel ? gettechparam(s, techkey, "min_power", "dispatchable") : 0.0) : min_power
            _min_uptime = isnothing(min_uptime) ? (excel ? gettechparam(s, techkey, "min_uptime", "dispatchable") : 0.0) : min_uptime
            _min_downtime = isnothing(min_downtime) ? (excel ? gettechparam(s, techkey, "min_downtime", "dispatchable") : 0.0) : min_downtime
            _startup_dur = isnothing(startup_duration) ? (excel ? gettechparam(s, techkey, "startup_duration", "dispatchable") : 0.0) : startup_duration
            _shutdown_dur = isnothing(shutdown_duration) ? (excel ? gettechparam(s, techkey, "shutdown_duration", "dispatchable") : 0.0) : shutdown_duration
            @argcheck _min_power isa Real "min_power must be Real."
            @argcheck _min_uptime isa Real "min_uptime must be Real."
            @argcheck _min_downtime isa Real "min_downtime must be Real."
            @argcheck _startup_dur isa Real "startup_duration must be Real."
            @argcheck _shutdown_dur isa Real "shutdown_duration must be Real."
            if _refuel
                push!(vb, Nosy.UnitCommitment("output", 
                    _min_power, 
                    uptime=_min_uptime, 
                    downtime=[_min_downtime, _refuel_duration],
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
        end
    end

    if !isnothing(_usize)
        _ru = isnothing(ramp_up) && excel ? gettechparam(s, techkey, "ramp_up", "dispatchable") : ramp_up
        _rd = isnothing(ramp_down) && excel ? gettechparam(s, techkey, "ramp_down", "dispatchable") : ramp_down
        @argcheck isnothing(_ru) || _ru isa Real "ramp_up must be Real or nothing."
        @argcheck isnothing(_rd) || _rd isa Real "ramp_down must be Real or nothing."
        @argcheck isnothing(_ru) || _ru >= 0 "ramp_up must be non negative."
        @argcheck isnothing(_rd) || _rd >= 0 "ramp_down must be non negative."
        if !isnothing(_ru) && !iszero(_ru)
            push!(vb, Ramping("output", :up, _ru * _usize, energy))
        end
        if !isnothing(_rd) && !iszero(_rd)
            push!(vb, Ramping("output", :down, _rd * _usize, energy))
        end
    else
        for (param, value) in (("ramp_up", ramp_up), ("ramp_down", ramp_down))
            if !isnothing(value)
                @argcheck value isa Real "$param must be Real or nothing."
                @argcheck value >= 0 "$param must be non negative."
                iszero(value) || throw(ArgumentError(
                    "`unit_size` must be supplied as a positive number when $param is non-zero",
                ))
            end
        end
    end
    
    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)
    if _refuel
        _ucb = first(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        # reduce capabilities of short shutdown
        for h in 1:8760
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

        # refuelling
        sum_refuel = AffExpr(0.)
        for h in 1:8760
            if !iszero((h-1)%_refuel_mask)
                e = _ucb.shutdownselector[2][h]
                if (e isa GenericAffExpr) && !iszero(e)
                    v = first(e.terms)[1]
                    fix(v, 0., force=true)
                end
            else
                add_to_expression!(sum_refuel, _ucb.shutdownselector[2][h])
            end
        end
        @constraint(s.sim.model, sum_refuel >= _refuel_fraction * nbunits(c))
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
    makeintermittentsource(name::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
        tech::String=name,
        cap=nothing, mincap=nothing, maxcap=nothing,
        weatheryear=nothing, profile=nothing,
        co2price=co2_price(s),
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
        fuel_cost::Union{Nothing,Real}=nothing, co2_emission::Union{Nothing,Real}=nothing,
    )

Build, connect and return an intermittent source component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `techkey`: technology column name in the `intermittent` tech data sheet.
  * `elec`: electricity node to connect the component to.
  * `co2`: CO2 node connected when `co2_emission` is non zero.
  * `s`: snapshot to register the component in.

  * `cap`: Output capacity in MW. A number fixes capacity, a JuMP `VariableRef` or
    `AffExpr` reuses that expression, `nothing` creates a capacity decision, and
    an extracted `Snapshot` inherits the capacity of `"<name> <node name>"` in it.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `weatheryear`: Year suffix used to select profile series `profiles_<year>`.
    Required for workbook lookup; unused when `profile` is supplied explicitly.
  * `profile`: Dimensionless hourly capacity-factor vector or scalar in `[0, 1]`.
    If `nothing`, read the `<techkey>_<node>` workbook column. With numeric
    `cap == 0`, an omitted profile is replaced by zero without a workbook or
    weather-year lookup.

  * `co2price`: Carbon price in currency/tCO2, used only when
    `co2_emission != 0`.

  * `overnight_cost`: Overnight CAPEX in currency/kW of output capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of output capacity.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.
  * `connection_cost`: Connection cost as a fraction of annualized investment.
  * `om_var_cost`, `fuel_cost`: Costs in currency/MWh of output.
  * `co2_emission`: Emission factor in kgCO2/MWh of output; converted to tCO2.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makeintermittentsource(name::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
    tech::String=name,
    # capacity / profile
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    weatheryear::Union{Nothing,Integer}=nothing, profile=nothing,

    co2price::Real=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
    fuel_cost::Union{Nothing,Real}=nothing, co2_emission::Union{Nothing,Real}=nothing,
)
    profile_value = cap isa Real && iszero(cap) && isnothing(profile) ? 0.0 : profile
    if isnothing(profile_value) && timeseries_mode(s) === :excel && isnothing(weatheryear)
        throw(ArgumentError(
            "`weatheryear` must be supplied when `profile` is read from the time-series workbook",
        ))
    end
    profile_sheet = isnothing(weatheryear) ? nothing : "profiles_$weatheryear"
    m = ProfileSource(elec.carrier, _resolve_timeseries(
        s, profile_value, techkey * "_" * elec.name, profile_sheet;
        keyword="profile", lower=0.0, upper=1.0,
    ))
    vb = []
    excel = tech_mode(s) === :excel
    if excel
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, techkey, "overnight_cost", "intermittent") : overnight_cost
        _conn = isnothing(connection_cost) ? gettechparam(s, techkey, "connection_cost", "intermittent") : connection_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, techkey, "om_fixed_cost", "intermittent") : om_fixed_cost
        _vom = isnothing(om_var_cost) ? gettechparam(s, techkey, "om_var_cost", "intermittent") : om_var_cost
        _fuel = isnothing(fuel_cost) ? gettechparam(s, techkey, "fuel_cost", "intermittent") : fuel_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, techkey, "decommissioning", "intermittent") : decommissioning
        _co2_em = isnothing(co2_emission) ? gettechparam(s, techkey, "co2_emission", "intermittent") : co2_emission
    else
        _oc_raw = something(overnight_cost, 0.0)
        _conn = something(connection_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _vom = something(om_var_cost, 0.0)
        _fuel = something(fuel_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _co2_em = something(co2_emission, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, techkey, "lifetime", "intermittent") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, techkey, "construction_profile", "intermittent") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, techkey, "decommissioning_profile", "intermittent") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, connection_cost=_conn, om_fixed_cost=_fom,
        om_var_cost=_vom, fuel_cost=_fuel, decommissioning=_decom, co2_emission=_co2_em,
    )
    validate_component_input(inputs)

    _inv = iszero(_oc_raw) ? 0.0 : eac(_oc_raw * 1000.0, discountrate(s), Int(_lt_raw), _cp)
    _decom_cost = if iszero(_oc_raw) || iszero(_decom)
        0.0
    else
        decom_cost(_oc_raw * 1000.0, _decom, Int(_lt_raw), discountrate(s), _dcp)
    end
    push!(vb, FixedCost(:investment, "output", energy, _inv))
    push!(vb, FixedCost(:connection, "output", energy, _inv * _conn))
    push!(vb, FixedCost(:fom, "output", energy, _fom * 1000.))
    push!(vb, VariableCost(:vom, "output", energy, _vom))
    push!(vb, VariableCost(:fuel, "output", energy, _fuel))
    push!(vb, FixedCost(:decommissioning, "output", energy, _decom_cost))
    if !iszero(_co2_em)
        push!(vb, LinkedJointFlow("co2", co2.carrier, :output, "output", x->x[1] * _co2_em / 1000.))
        push!(vb, VariableCost(:co2, "co2", Nosy.co2, co2price))
    end
    push!(vb, gencapacity(cap, "output", s, name * " " * elec.name; mincap=mincap, maxcap=maxcap))
    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    if !iszero(_co2_em)
        connect!(s, c, co2)
    end
    for t in ("generation", "intermittent")
        tag!(c, :function, t)
    end
    iszero(_co2_em) && tag!(c, :function, "carbonfree")
    return c
end

"""
    makehydroror(name::String, zone::String, elec::Node, s::Snapshot;
        tech::String=name, cap=nothing, mincap=nothing, maxcap=nothing,
        techkey::String="Hydro ror", weatheryear=nothing,
        intake, intake_profile=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a run of river hydro component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `zone`: Time series zone used to read the hydro intake profile.
  * `elec`: electricity node to connect the component to.
  * `s`: snapshot to register the component in.

  * `cap`: Output capacity in MW. A number fixes capacity, `nothing` creates a new
    capacity decision, a JuMP variable or affine expression reuses that external
    decision, and an extracted `Snapshot` inherits the capacity of
    `"<name> <node name>"` in it.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `techkey`: technology column name in the `intermittent` tech data sheet.
  * `weatheryear`: Year suffix used to select intake series `hydro_ror_<year>`.
    Required for workbook lookup; unused when `intake_profile` is supplied
    explicitly.
  * `intake_profile`: Dimensionless hourly run-of-river intake shape or scalar,
    nonnegative with a strictly positive sum. The profile is normalized to sum
    to one before the total intake is applied. If `nothing`, read `zone` from
    the selected workbook sheet.

  * `intake`: Total intake in MWh over the modeled profile (normally one year).
    `0` disables intake and skips the zone, profile, and weather-year lookup.

  * `overnight_cost`: Overnight CAPEX in currency/kW of output capacity.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of output capacity.
  * `om_var_cost`: Variable O&M in currency/MWh of output.
  * `decommissioning`: Decommissioning cost as a fraction of overnight CAPEX.
  * `lifetime`: Asset lifetime in years (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares.
  * `decommissioning_profile`: Dimensionless yearly decommissioning-cost shares.

With `nothing`, economic arguments use workbook values in `:excel` mode. In
`:arguments` mode, costs default to zero; nonzero overnight cost requires
`lifetime` and `construction_profile`, plus `decommissioning_profile` when
decommissioning is nonzero.
"""
function makehydroror(name::String, zone::String, elec::Node, s::Snapshot;
    tech::String=name,
    # capacity / profile
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    techkey::String="Hydro ror", weatheryear::Union{Nothing,Integer}=nothing, intake_profile=nothing,

    intake::Real,

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    om_var_cost::Union{Nothing,Real}=nothing, decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing,
    construction_profile=nothing, decommissioning_profile=nothing,
)
    @argcheck isfinite(intake) && intake >= 0 "makehydroror `intake` must be finite and non-negative."
    intake_series = if iszero(intake)
        zeros(Nosy.nhours(sim(s)))
    else
        if isnothing(intake_profile) && timeseries_mode(s) === :excel && isnothing(weatheryear)
            throw(ArgumentError(
                "`weatheryear` must be supplied when `intake_profile` is read from the time-series workbook",
            ))
        end
        profile_sheet = isnothing(weatheryear) ? nothing : "hydro_ror_$weatheryear"
        profile = _resolve_timeseries(
            s, intake_profile, zone, profile_sheet;
            keyword="intake_profile", lower=0.0,
        )
        profile_sum = sum(profile)
        @argcheck profile_sum > 0 "run-of-river intake profile must have a positive sum."
        profile / profile_sum * intake
    end
    m = DispatchableSource(elec.carrier)
    vb = []
    push!(vb, gencapacity(cap, "output", s, name * " " * elec.name; mincap=mincap, maxcap=maxcap))

    # costs
    excel = tech_mode(s) === :excel
    if excel
        _oc_raw = isnothing(overnight_cost) ? gettechparam(s, techkey, "overnight_cost", "intermittent") : overnight_cost
        _fom = isnothing(om_fixed_cost) ? gettechparam(s, techkey, "om_fixed_cost", "intermittent") : om_fixed_cost
        _decom = isnothing(decommissioning) ? gettechparam(s, techkey, "decommissioning", "intermittent") : decommissioning
        _vom = isnothing(om_var_cost) ? gettechparam(s, techkey, "om_var_cost", "intermittent") : om_var_cost
    else
        _oc_raw = something(overnight_cost, 0.0)
        _fom = something(om_fixed_cost, 0.0)
        _decom = something(decommissioning, 0.0)
        _vom = something(om_var_cost, 0.0)
    end

    _lt_raw = lifetime
    _cp = nothing
    if !iszero(_oc_raw)
        if isnothing(_lt_raw)
            _lt_raw = excel ? gettechparam(s, techkey, "lifetime", "intermittent") : throw(ArgumentError(
                "`lifetime` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        end
        _cp = if isnothing(construction_profile)
            excel ? gettechparam(s, techkey, "construction_profile", "intermittent") : throw(ArgumentError(
                "`construction_profile` must be supplied when overnight_cost is non-zero and tech_mode=:arguments",
            ))
        else
            construction_profile
        end
    end

    _dcp = nothing
    if !iszero(_oc_raw) && !iszero(_decom)
        _dcp = if isnothing(decommissioning_profile)
            excel ? gettechparam(s, techkey, "decommissioning_profile", "intermittent") : throw(ArgumentError(
                "`decommissioning_profile` must be supplied when overnight_cost and decommissioning are non-zero and tech_mode=:arguments",
            ))
        else
            decommissioning_profile
        end
    end

    inputs = component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, om_fixed_cost=_fom,
        decommissioning=_decom, om_var_cost=_vom,
    )
    validate_component_input(inputs)

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

    c = Component(name * " " * elec.name, m, vb)
    output = energy(Nosy.getport(c, "output"))
    intake_envelope = Nosy.Stepwise(intake_series, Nosy.mesh(c))
    @constraint(lowermodel(sim(c)), output.data .<= intake_envelope.data)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    for t in ("generation", "intermittent", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end
