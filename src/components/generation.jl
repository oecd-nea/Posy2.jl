"""
Generate generation-side components.
"""

using ArgCheck: @argcheck

"""
    makedispatchable(cname::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
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
  * `cname`: component name prefix.
  * `techkey`: technology column name in the `dispatchable` tech data sheet.
  * `elec`: Electricity node connected to component output flow.
  * `co2`: CO2 node connected only when `co2_emission != 0`.
  * `s`: Target snapshot where the component and behaviors are registered.

  * `cap`: Output capacity in model power units. A number fixes capacity, a
    JuMP `VariableRef` or `AffExpr` reuses that expression, `nothing` creates a
    capacity decision, and an extracted `Snapshot` inherits the capacity of
    `"<cname> <node name>"` in it. Numeric `0` builds a zero-capacity component.
  * `mincap`: Lower bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `capacitymultiplier`: Time varying multiplier applied to output capacity (capacity basis, not energy basis).

  * `integeruc`: If `true`, UC commitment variables are integer (mixed integer UC).
  * `uc`: Enables UC constraints and UC linked costs (`no_load_cost`, `startup_cost`).
    An extracted `Snapshot` instead replays the commitment schedule already
    solved for the matching component, and then requires a fixed `cap`.
  * `fuelnode`: If provided, fuel is modeled as an input flow linked by efficiency. If `nothing`, fuel is modeled as a variable cost on output energy (`fuel_cost`).

  * `co2price`: CO2 cost coefficient used with emitted CO2 flow.

  * `overnight_cost`: Overnight CAPEX input used by `eac(...)`. Defaults to `0` in `:arguments` mode.
  * `om_fixed_cost`: Fixed O&M cost on output capacity (`FixedCost(:fom, "output", ...)`). Defaults to `0` in `:arguments` mode.
  * `decommissioning`: Decommissioning cost ratio used in `decom_cost(...)`. Defaults to `0` in `:arguments` mode.
  * `lifetime`: Asset lifetime used by annualization/decommissioning calculations (`> 0`, integer-valued). Required when `overnight_cost != 0`.
  * `construction_profile`: Construction cost share profile passed to `eac(...)`. Required when `overnight_cost != 0`.
  * `decommissioning_profile`: Decommissioning cost share profile passed to `decom_cost(...)`. Required when both `overnight_cost` and `decommissioning` are non-zero.
  * `connection_cost`: Connection cost ratio applied on annualized investment. Defaults to `0` in `:arguments` mode.
  * `om_var_cost`: Variable O&M cost on output energy flow (`VariableCost(:vom, "output", ...)`). Defaults to `0` in `:arguments` mode.
  * `fuel_cost`: Direct fuel variable cost on output energy. Used only when `fuelnode === nothing` and defaults to `0` in `:arguments` mode.
  * `no_load_cost`: UC no load cost applied per committed output state and time step. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
  * `startup_cost`: UC startup cost applied to startup events. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
  * `co2_emission`: CO2 emission factor linked from output energy to CO2 flow (`output * co2_emission / 1000`). Defaults to `0` in `:arguments` mode.
  * `efficiency`: Fuel to output conversion efficiency for linked fuel flow. Used only when `fuelnode` is provided and defaults to lossless `1` in `:arguments` mode.
  * `unit_size`: Unit block size for discrete capacity representation. In `:arguments` mode, `nothing` disables unit sizing. Use `0` to override an Excel value with no unit sizing. A positive value is required when `uc=true`.
  * `ramp_up`: Max ramp up as a fraction of unit capacity per hour. Passed to `Ramping(...)` as `ramp_up * unit_size`. Omitted or `nothing` adds no constraint in `:arguments` mode.
  * `ramp_down`: Max ramp down as a fraction of unit capacity per hour. Same scaling as `ramp_up`. Omitted or `nothing` adds no constraint in `:arguments` mode.
  * `min_power`: UC minimum generation fraction while committed. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
  * `min_uptime`: minimum consecutive online time in hours after a start. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
  * `min_downtime`: minimum consecutive offline time in hours after a shutdown. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
  * `startup_duration`: offline-to-online transition duration in hours. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
  * `shutdown_duration`: online-to-offline transition duration in hours. Used only when `uc=true` and defaults to `0` in `:arguments` mode.
"""
function makedispatchable(cname::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
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
    push!(vb, gencapacity(cap, "output", s, cname * " " * elec.name;
        mincap=mincap, maxcap=maxcap, unitsize=_usize))

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
            _pushinheriteduc!(vb, uc, cname * " " * elec.name, "output")
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

    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
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
    makenuclear(cname::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing, integercap=false, warmstart=nothing,
        uc=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,
        reload_duration::Union{Nothing,Real}=nothing, reloadmask::Union{Nothing,Real}=nothing, reload_fraction_per_year::Union{Nothing,Real}=nothing,
        fuelnode=nothing, co2price=co2_price(s),
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
        connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing, fuel_cost::Union{Nothing,Real}=nothing,
        waste_cost::Union{Nothing,Real}=nothing, no_load_cost::Union{Nothing,Real}=nothing, startup_cost::Union{Nothing,Real}=nothing,
        co2_emission::Union{Nothing,Real}=nothing, efficiency::Union{Nothing,Real}=nothing, unit_size::Union{Nothing,Real}=nothing,
        min_power::Union{Nothing,Real}=nothing, min_uptime::Union{Nothing,Real}=nothing, min_downtime::Union{Nothing,Real}=nothing,
        startup_duration::Union{Nothing,Real}=nothing, shutdown_duration::Union{Nothing,Real}=nothing,
    )

Build, connect and return a nuclear reactor component.

Arguments:
  * `cname`: component name prefix.
  * `techkey`: technology column name in the `dispatchable` tech data sheet.
  * `elec`: electricity node to connect the component to.
  * `co2`: CO2 node connected when `co2_emission` is non zero.
  * `s`: snapshot to register the component in.

  * `cap`: Output capacity. A number fixes capacity, a JuMP `VariableRef` or
    `AffExpr` reuses that expression, `nothing` creates a capacity decision, and
    an extracted `Snapshot` inherits the capacity of `"<cname> <node name>"` in it.
  * `mincap`: Lower bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `integercap`: Integer flag for capacity expansion variable.
  * `warmstart`: Warm start value passed to variable capacity behavior when used.

  * `uc`: Enables UC constraints and UC linked costs. An extracted `Snapshot`
    instead replays the commitment schedule already solved for the matching
    component, and then requires a fixed `cap`. Reloading logic is only modeled when unit commitment is enabled; if `uc=false` and any reloading argument is provided, a warning is emitted and reloading is ignored.
  * `integeruc`: Integer UC commitment variables.
  * `startupmask`: Optional masks restricting UC startup/shutdown availability over time.
  * `shutdownmask`: Optional masks restricting UC startup/shutdown availability over time.

  * `reload_duration`: Duration of planned reload outage. If `nothing`, read from the technology workbook. Must be >= 0; reloading constraints are enabled only when this value is > 0.
  * `reloadmask`: Interval between allowed reload windows. Non default parameter (not read from the technology workbook). When reloading is enabled, it must be provided , strictly positive, and integer-valued.
  * `reload_fraction_per_year`: Minimum yearly reload requirement (fraction per unit per year). If `nothing`, read from the technology workbook. Must be >= 0; reloading constraints are enabled only when this value is > 0.

  * `fuelnode`: If provided, fuel is represented as linked input flow using `efficiency`. If `nothing`, `fuel_cost` is applied as output variable cost.
  * `co2price`: CO2 price coefficient for emitted CO2 flow.

  * `overnight_cost`: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Workbook defaults are used when values are `nothing`.
  * `om_fixed_cost`: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning`: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Workbook defaults are used when values are `nothing`.
  * `lifetime`: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms (`> 0`, integer-valued). Workbook defaults are used when values are `nothing`.
  * `construction_profile`: Cost/lifetime inputs for annualized CAPEX, FOM, and decommissioning terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning_profile`: Decommissioning cost share profile passed to `decom_cost(...)`. Workbook defaults are used when values are `nothing`.
  * `connection_cost`: Ratio applied to annualized investment for connection cost.
  * `om_var_cost`: Variable cost coefficients on output energy (fuel cost used directly only when `fuelnode === nothing`).
  * `fuel_cost`: Variable cost coefficients on output energy (fuel cost used directly only when `fuelnode === nothing`).
  * `waste_cost`: Variable cost coefficients on output energy (fuel cost used directly only when `fuelnode === nothing`).
  * `no_load_cost`: UC specific costs added only when `uc=true`.
  * `startup_cost`: UC specific costs added only when `uc=true`.
  * `co2_emission`: Emission factor linking output energy to CO2 output flow.
  * `efficiency`: Fuel to output efficiency for linked fuel input mode.
  * `unit_size`: Unit block size for discrete capacity representation.
  * `min_power`: UC minimum generation fraction while committed. Used only when `uc=true`.
  * `min_uptime`: minimum consecutive online time in hours after a start. Used only when `uc=true`.
  * `min_downtime`: minimum consecutive offline time in hours after a shutdown. Used only when `uc=true`.
  * `startup_duration`: offline-to-online transition duration in hours. Used only when `uc=true`.
  * `shutdown_duration`: online-to-offline transition duration in hours. Used only when `uc=true`.
"""
function makenuclear(cname::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing, mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,
    integercap=false, warmstart::Union{Nothing,Real}=nothing,

    # unit commitment / operation
    uc::Union{Bool,Snapshot}=false, integeruc=false, startupmask=nothing, shutdownmask=nothing,

    # reloading controls
    reload_duration::Union{Nothing,Real}=nothing, reloadmask::Union{Nothing,Real}=nothing, reload_fraction_per_year::Union{Nothing,Real}=nothing,

    # external nodes / prices
    fuelnode=nothing, co2price::Real=co2_price(s),

    # technical / economic overrides
    overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing,
    decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    connection_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing, fuel_cost::Union{Nothing,Real}=nothing,
    waste_cost::Union{Nothing,Real}=nothing, no_load_cost::Union{Nothing,Real}=nothing,
    startup_cost::Union{Nothing,Real}=nothing, co2_emission::Union{Nothing,Real}=nothing, efficiency::Union{Nothing,Real}=nothing,
    unit_size::Union{Nothing,Real}=nothing, min_power::Union{Nothing,Real}=nothing,
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
    push!(vb, gencapacity(cap, "output", s, cname * " " * elec.name;
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
    _reload_on = false
    if !_ucenabled(uc) && (!isnothing(reload_duration) || !isnothing(reloadmask) || !isnothing(reload_fraction_per_year))
        @warn "Because uc=false for nuclear component, reloading is not modeled." component=cname techkey=techkey
    end
    if uc isa Snapshot && (!isnothing(reload_duration) || !isnothing(reloadmask) || !isnothing(reload_fraction_per_year))
        @warn "Because uc replays a solved schedule for nuclear component, reloading follows that schedule and reload arguments are ignored." component=cname techkey=techkey
    end
    # reload constraints are built from fresh arguments, never over a replayed schedule
    if uc === true
        _reload_fraction = if isnothing(reload_fraction_per_year)
            excel ? gettechparam(s, techkey, "reload_fraction_per_year", "dispatchable") : 0.0
        else
            reload_fraction_per_year
        end
        @argcheck _reload_fraction isa Real "reload_fraction_per_year must be Real."
        @argcheck _reload_fraction >= 0 "reload_fraction_per_year must be >= 0."
        if _reload_fraction > 0
            _reload_duration = if isnothing(reload_duration)
                excel ? gettechparam(s, techkey, "reload_duration", "dispatchable") : 0.0
            else
                reload_duration
            end
            @argcheck _reload_duration isa Real "reload_duration must be Real."
            @argcheck _reload_duration >= 0 "reload_duration must be >= 0."
            _reload_on = (_reload_fraction > 0) && (_reload_duration > 0)
            if _reload_on
                @argcheck !isnothing(reloadmask) "reloadmask must be provided when reloading is enabled."
                _reload_mask_raw = reloadmask
                @argcheck _reload_mask_raw isa Real "reloadmask must be Real."
                @argcheck _reload_mask_raw > 0 "reloadmask must be > 0 when reloading is enabled."
                @argcheck isinteger(_reload_mask_raw) "reloadmask must be integer-valued."
                _reload_mask = Int(_reload_mask_raw)
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
            _pushinheriteduc!(vb, uc, cname * " " * elec.name, "output")
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
        end
    end
    
    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    if _reload_on
        _ucb = first(Nosy.getbehaviors(c, Nosy.AbstractFleetUnitCommitmentBehavior))
        if techkey in ("Nuclear", "Nuclear flexible",)
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
        elseif techkey == "SMR"
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
    makeintermittentsource(cname::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
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
  * `cname`: component name prefix.
  * `techkey`: technology column name in the `intermittent` tech data sheet.
  * `elec`: electricity node to connect the component to.
  * `co2`: CO2 node connected when `co2_emission` is non zero.
  * `s`: snapshot to register the component in.

  * `cap`: Output capacity. A number fixes capacity, a JuMP `VariableRef` or
    `AffExpr` reuses that expression, `nothing` creates a capacity decision, and
    an extracted `Snapshot` inherits the capacity of `"<cname> <node name>"` in it.
  * `mincap`: Lower bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `weatheryear`: Year suffix used to select profile series `profiles_<year>`.
    Required for workbook lookup; unused when `profile` is supplied explicitly.
  * `profile`: Hourly capacity-factor vector or scalar, each value in `[0, 1]`.
    If `nothing`, read the `<techkey>_<node>` workbook column.

  * `co2price`: CO2 cost coefficient applied to emitted CO2 flow.

  * `overnight_cost`: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `om_fixed_cost`: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning`: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `lifetime`: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms (`> 0`, integer-valued). Workbook defaults are used when values are `nothing`.
  * `construction_profile`: CAPEX/FOM/lifetime inputs used in annualized fixed cost terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning_profile`: Decommissioning cost share profile passed to `decom_cost(...)`. Workbook defaults are used when values are `nothing`.
  * `connection_cost`: Ratio applied to annualized investment as connection fixed cost.
  * `om_var_cost`: Variable O&M coefficient on output energy flow.
  * `fuel_cost`: Fuel variable cost coefficient on output energy flow.
  * `co2_emission`: Emission factor linking output energy to CO2 output flow.
"""
function makeintermittentsource(cname::String, techkey::String, elec::Node, co2::Node, s::Snapshot;
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
    push!(vb, gencapacity(cap, "output", s, cname * " " * elec.name; mincap=mincap, maxcap=maxcap))
    c = Component(cname * " " * elec.name, m, vb)
    tag!(c, :tech, cname)
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
    makehydroror(cname::String, zone::String, elec::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing,
        techkey::String="Hydro ror", weatheryear=nothing,
        intake, intake_profile=nothing,
        overnight_cost::Union{Nothing,Real}=nothing, om_fixed_cost::Union{Nothing,Real}=nothing, om_var_cost::Union{Nothing,Real}=nothing,
        decommissioning::Union{Nothing,Real}=nothing, lifetime::Union{Nothing,Real}=nothing, construction_profile=nothing, decommissioning_profile=nothing,
    )

Build, connect and return a run of river hydro component.

Arguments:
  * `cname`: component name prefix.
  * `zone`: Time series zone used to read the hydro intake profile.
  * `elec`: electricity node to connect the component to.
  * `s`: snapshot to register the component in.

  * `cap`: Output capacity. A number fixes capacity, `nothing` creates a new
    capacity decision, a JuMP variable or affine expression reuses that external
    decision, and an extracted `Snapshot` inherits the capacity of
    `"<cname> <node name>"` in it.
  * `mincap`: Lower bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper bound on an optimized or externally supplied capacity;
    checked as an assertion against a fixed or inherited one.
  * `techkey`: technology column name in the `intermittent` tech data sheet.
  * `weatheryear`: Year suffix used to select intake series `hydro_ror_<year>`.
    Required for workbook lookup; unused when `intake_profile` is supplied
    explicitly.
  * `intake_profile`: Hourly run-of-river intake shape or scalar, nonnegative
    with a strictly positive sum. The profile is normalized to sum to one before
    the total intake is applied. If `nothing`, read `zone` from the selected
    workbook sheet.

  * `intake`: Total intake distributed over the normalized intake profile.

  * `overnight_cost`: Cost/lifetime overrides for fixed and variable hydro cost terms. Workbook defaults are used when values are `nothing`.
  * `om_fixed_cost`: Cost/lifetime overrides for fixed and variable hydro cost terms. Workbook defaults are used when values are `nothing`.
  * `om_var_cost`: Cost/lifetime overrides for fixed and variable hydro cost terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning`: Cost/lifetime overrides for fixed and variable hydro cost terms. Workbook defaults are used when values are `nothing`.
  * `lifetime`: Cost/lifetime overrides for fixed and variable hydro cost terms (`> 0`, integer-valued). Workbook defaults are used when values are `nothing`.
  * `construction_profile`: Cost/lifetime overrides for fixed and variable hydro cost terms. Workbook defaults are used when values are `nothing`.
  * `decommissioning_profile`: Decommissioning cost share profile passed to `decom_cost(...)`. Workbook defaults are used when values are `nothing`.
"""
function makehydroror(cname::String, zone::String, elec::Node, s::Snapshot;
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
    push!(vb, gencapacity(cap, "output", s, cname * " " * elec.name; mincap=mincap, maxcap=maxcap))

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

    c = Component(cname * " " * elec.name, m, vb)
    output = energy(Nosy.getport(c, "output"))
    intake_envelope = Nosy.Stepwise(intake_series, Nosy.mesh(c))
    @constraint(lowermodel(sim(c)), output.data .<= intake_envelope.data)
    tag!(c, :tech, cname)
    tag!(c, :zone, elec.name)
    connect!(s, c, elec)
    for t in ("generation", "intermittent", "carbonfree")
        tag!(c, :function, t)
    end
    return c
end
