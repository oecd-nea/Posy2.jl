"""
Generate interconnection components.
"""

"""
    makepricelink(name::String, elec::Node, s::Snapshot;
        neighbor::String=name, neighbor_column::String=neighbor,
        import_capacity=nothing, import_mincap=nothing, import_maxcap=nothing,
        export_capacity=nothing, export_mincap=nothing, export_maxcap=nothing,
        dir::Bool=false, neighbor_is_foreign::Bool=true,
        transactioncost::Real=0.,
        spot_price=nothing, import_availability=nothing, export_availability=nothing,
    )

Build, connect and return an interconnection component named
`"<name>_<elec.name>"`, trading with a neighbouring market represented by an
exogenous price series instead of an explicit node.
If `dir` is true, apply a one direction at a time constraint at every timestep.

Arguments:
  * `name`: interconnector name prefix.
  * `elec`: local electricity node to connect the interconnector to.
  * `s`: snapshot to register the component in.

  * `neighbor`: counterparty market, reported as the `:neighbor` tag and as the
    remote endpoint of directed flows. Defaults to `name`.
  * `neighbor_column`: name the workbook columns are built from. Defaults to
    `neighbor`.

  * `import_capacity`: Import capacity in MW, following the common capacity
    contract: a number fixes it, a JuMP `VariableRef` or `AffExpr` reuses that
    expression, `nothing` creates a capacity decision, and an extracted
    `Snapshot` inherits the `"output"` capacity of `"<name>_<elec.name>"` in it.
    Numeric `0` disables imports.
  * `import_mincap`: Lower import capacity bound in MW; checked as an assertion
    against a fixed or inherited one.
  * `import_maxcap`: Upper import capacity bound in MW; checked as an assertion
    against a fixed or inherited one.
  * `export_capacity`: Export capacity in MW, with the same contract; an
    extracted `Snapshot` inherits the `"input"` capacity. Numeric `0` disables
    exports.
  * `export_mincap`: Lower export capacity bound in MW.
  * `export_maxcap`: Upper export capacity bound in MW.

  * `dir`: if `true`, apply SOS1 one direction at a time flow constraint.
  * `neighbor_is_foreign`: if `true`, the neighbouring market lies outside the
    modelled system and the component is tagged `:foreign`. A price
    interconnection carries this on itself because its remote endpoint is not a
    node that could hold a `:foreign` tag, unlike
    [`maketransmissionlink`](@ref). Set it to false when the price series
    represents another internal zone.

  * `transactioncost`: Transaction adder in currency/MWh on both directions.
  * `spot_price`: Foreign spot price in currency/MWh, as an hourly vector or scalar.
  * `import_availability`: Dimensionless hourly multiplier for the
    foreign-to-local direction, each value in `[0, 1]`, read from column
    `"<neighbor_column>><elec.name>"`.
  * `export_availability`: Dimensionless hourly multiplier for the
    local-to-foreign direction, with the same `[0, 1]` domain, read from column
    `"<elec.name>><neighbor_column>"`.
    Availability is resolved for every direction except a numeric zero one. When
    omitted, it comes from the workbook in `:excel` mode and defaults to one in
    `:arguments` mode. `spot_price` is required whenever either direction has
    active capacity, and is read from column `"<neighbor_column>"`. When both
    capacities are numeric zeros the corridor is disabled: no spot price is read
    and the reported exogenous price is an hourly series of zeros.

Neither direction carries an investment cost, so bound an optimized capacity
with `import_maxcap` or `export_maxcap`.
"""
function makepricelink(name::String, elec::Node, s::Snapshot;
    # identity
    neighbor::String=name, neighbor_column::String=neighbor,

    # capacity / expansion
    import_capacity::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    import_mincap::Union{Nothing,Real}=nothing, import_maxcap::Union{Nothing,Real}=nothing,
    export_capacity::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    export_mincap::Union{Nothing,Real}=nothing, export_maxcap::Union{Nothing,Real}=nothing,

    # operation flags
    dir::Bool=false, neighbor_is_foreign::Bool=true,

    # economic controls
    transactioncost::Real=0.,
    spot_price=nothing, import_availability=nothing, export_availability=nothing,
)
    component_name = string(name, "_", elec.name)
    # inheritance is resolved first, so that an inherited zero disables its
    # direction exactly like a numeric zero
    _mcap = import_capacity isa Snapshot ?
        _inheritedcapacity(import_capacity, component_name, "output", "import_capacity") :
        import_capacity
    _xcap = export_capacity isa Snapshot ?
        _inheritedcapacity(export_capacity, component_name, "input", "export_capacity") :
        export_capacity
    imports_active = !(_mcap isa Real && iszero(_mcap))
    exports_active = !(_xcap isa Real && iszero(_xcap))

    vb = []
    _imports = if imports_active
        input = isnothing(import_availability) && timeseries_mode(s) === :arguments ? 1.0 : import_availability
        _resolve_timeseries(
            s, input, neighbor_column * ">" * elec.name, "transfer_capacities";
            keyword="import_availability", lower=0.0, upper=1.0,
        )
    end
    _exports = if exports_active
        input = isnothing(export_availability) && timeseries_mode(s) === :arguments ? 1.0 : export_availability
        _resolve_timeseries(
            s, input, elec.name * ">" * neighbor_column, "transfer_capacities";
            keyword="export_availability", lower=0.0, upper=1.0,
        )
    end
    _spot = if imports_active || exports_active
        _resolve_timeseries(
            s, spot_price, neighbor_column, "spot_price"; keyword="spot_price", digits=2,
        )
    else
        # a fully disabled corridor has no price to resolve, but reporting still
        # expects an hourly series
        zeros(Nosy.nhours(sim(s)))
    end

    # imports
    m = DispatchableSource(elec.carrier)
    push!(vb, gencapacity(
        _mcap, "output", s, component_name;
        mincap=import_mincap, maxcap=import_maxcap, argname="import_capacity",
    ))
    imports_active && push!(vb, Nosy.CapacityMultiplier("output", _imports))
    push!(vb, VariableCost(:imports, "output", energy, _spot))
    push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))

    # exports
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, gencapacity(
        _xcap, "input", s, component_name;
        mincap=export_mincap, maxcap=export_maxcap, argname="export_capacity",
    ))
    exports_active && push!(vb, Nosy.CapacityMultiplier("input", _exports))
    push!(vb, VariableCost(:exports, "input", energy, -1 .* _spot))
    push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))

    c = Component(component_name, m, vb)

    # make the IC flow go in one direction only
    if dir
        bin = balance(c, :input, energy, collapse=false, aggregate=true)
        bout = balance(c, :output, energy, collapse=false, aggregate=true)
        for step in eachindex(bin)
            @constraint(Nosy.sim(s).model, [bin[step], bout[step]] in SOS1())
        end
    end
    for t in ("interconnection", "priceinterconnection")
        tag!(c, :function, t)
    end
    if neighbor_is_foreign
        tag!(c, :function, "foreign")
    end
    tag!(c, :neighbor, neighbor)
    connect!(s, c, elec)
    tag!(c, :zone, elec.name)

    return c
end

"""
    maketransmissionlink(name::String, a::Node, b::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing,
        dir::Bool=false, dc::Bool=false,
        transactioncost::Real=0., lossfactor::Real=0.,
        susceptance::Union{Nothing,Real}=nothing,
        atob_availability=nothing, btoa_availability=nothing,
        overnight_cost=nothing, om_fixed_cost=nothing,
        lifetime=nothing, construction_profile=nothing,
    )

Build, connect and return an interconnection component linking two nodes.
Whether the link crosses the self-system boundary is derived at reporting time
from the connected nodes' `:foreign` tags; there is no component-level flag.

Arguments:
  * `name`: interconnector name prefix.
  * `a`: first node linked by the interconnector.
  * `b`: distinct second node linked by the interconnector; self-connections
    are rejected before model construction.
  * `s`: snapshot to register the component in.

  * `cap`: Installed capacity in MW. A number fixes
    capacity, a JuMP `VariableRef` or `AffExpr` reuses that expression,
    `nothing` creates a capacity decision, and an extracted `Snapshot` inherits
    the capacity of `"<name>_<a.name>_<b.name>"` in it. Numeric `0` builds a
    zero-capacity component.
  * `mincap`: Lower capacity bound in MW;
    checked as an assertion against a fixed or inherited one.
  * `maxcap`: Upper capacity bound in MW;
    checked as an assertion against a fixed or inherited one.

  * `dir`: apply an SOS1 one direction at a time flow constraint.
  * `dc`: if `true`, tag as `:DC`; otherwise tag as `:AC`.

  * `transactioncost`: Transaction adder in currency/MWh on each direction.
  * `lossfactor`: Dimensionless proportional loss; must be finite and
    satisfy `0 <= lossfactor < 1`.
  * `susceptance`: AC series susceptance in model power units/rad (MW/rad under
    the standard convention; must be negative), used only when `dc=false`;
    stored in `Snapshot.options[:ic_susceptance]` (required for KVL when
    [`applydcopf!`](@ref) is called).
  * `atob_availability`: Dimensionless hourly `a -> b` multiplier vector or
    scalar, each value in `[0, 1]`.
  * `btoa_availability`: Dimensionless hourly `b -> a` multiplier vector or
    scalar, with the same `[0, 1]` domain. These directional multipliers
    represent asymmetric available transfer capacity against the shared
    installed capacity. A nonzero fixed or optimized capacity reads both
    workbook columns in `:excel` mode when omitted, and defaults both to one in
    `:arguments` mode. Numeric zero does not resolve either availability series.
  * `overnight_cost`: Overnight CAPEX in currency/kW of shared capacity.
    Defaults to zero.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of shared capacity.
    Defaults to zero.
  * `lifetime`: Asset lifetime in years, used to annualize nonzero overnight
    cost (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares,
    required when `overnight_cost` is nonzero.

In `:excel` mode both directional multipliers are read from the sheet that
matches the link type: `transfer_capacities_AC` when `dc=false`,
`transfer_capacities_DC` when `dc=true`. Columns are named `From>To` after the
node names. An AC and a DC link on the same node pair therefore carry their own
availability series, and neither reads `transfer_capacities`, which belongs to
[`makepricelink`](@ref).

Node interconnections cannot be added after [`applydcopf!`](@ref) has run on the
snapshot; build the full topology first.

Exactly one `AC` and one `DC` may share the same unordered node pair
(either, both, or neither is fine). A second `AC` or a second `DC` on
that pair raises an error. Component-name collisions are also rejected before
model construction. Aggregate equivalent parallel circuits before calling
this builder.
"""
function maketransmissionlink(name::String, a::Node, b::Node, s::Snapshot;
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,

    # operation flags
    dir::Bool=false, dc::Bool=false,

    # economic / physical controls
    transactioncost::Real=0., lossfactor::Real=0.,
    susceptance::Union{Nothing,Real}=nothing,
    atob_availability=nothing, btoa_availability=nothing,

    # economic controls
    overnight_cost::Union{Nothing,Real}=nothing,
    om_fixed_cost::Union{Nothing,Real}=nothing,
    lifetime::Union{Nothing,Real}=nothing,
    construction_profile=nothing,
)
    @argcheck 0 <= lossfactor < 1 "lossfactor must be in [0, 1)"
    component_name = string(name, "_", a.name, "_", b.name)
    a.name == b.name && throw(ArgumentError("a node interconnection must connect two distinct nodes"))
    Nosy.hascomponent(s, component_name) && throw(ArgumentError("snapshot already has a component named $component_name"))
    Nosy.hasnode(s, component_name) && throw(ArgumentError("snapshot already has a node named $component_name"))
    # KVL is built from the node ICs present when applydcopf! runs; a later IC
    # would leave those constraints describing a network that no longer exists.
    haskey(s.options, :kvl_applied) && throw(ArgumentError(
        "cannot add node interconnection $component_name after applydcopf!: the KVL constraints already in the model were built from the interconnections present at that time. Build the full topology before calling applydcopf!",
    ))

    # One AC and one DC may share a pair; a second AC or second DC is rejected.
    pair = Set([a.name, b.name])
    for (_, existing) in getcomponents(s; with=[:function => "nodeinterconnection"])
        Set(get(existing.tags, :zone, String[])) == pair || continue
        existing_dc = hastag(existing, :function, "DC")
        if existing_dc == dc
            kind = dc ? "DC" : "AC"
            throw(ArgumentError("a $kind node interconnection already exists between $(a.name) and $(b.name); parallel $kind ICs are not supported"))
        end
    end

    if !dc && !isnothing(susceptance)
        @argcheck susceptance < 0 "susceptance must be negative"
        if haskey(s.options, :ic_susceptance)
            registry = s.options[:ic_susceptance]
            registry isa Dict{Tuple{String, String}, Float64} || throw(ArgumentError(
                ":ic_susceptance must be Dict{Tuple{String,String},Float64}, got $(typeof(registry))",
            ))
        end
    end

    # AC and DC links keep separate worksheets: one node pair may carry both, and
    # each needs its own availability series.
    transfer_sheet = dc ? "transfer_capacities_DC" : "transfer_capacities_AC"

    _oc_raw = something(overnight_cost, 0.0)
    _fom = something(om_fixed_cost, 0.0)
    _lt_raw = lifetime
    _cp = construction_profile
    if !iszero(_oc_raw)
        isnothing(_lt_raw) && throw(ArgumentError(
            "`lifetime` must be supplied when overnight_cost is non-zero",
        ))
        isnothing(_cp) && throw(ArgumentError(
            "`construction_profile` must be supplied when overnight_cost is non-zero",
        ))
    end
    validate_component_input(component_input(
        overnight_cost=_oc_raw, lifetime=_lt_raw, om_fixed_cost=_fom,
    ))
    _inv = iszero(_oc_raw) ? 0.0 : eac(
        _oc_raw * 1000.0, discountrate(s), Int(_lt_raw), _cp,
    )

    # A node interconnection has one installed capacity. Both capacity
    # behaviors below reuse the same value or AffExpr.
    _cap = cap isa Snapshot ? _inheritedcapacity(cap, component_name, "input", "cap") : cap
    capacity_active = !(_cap isa Real && iszero(_cap))

    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1. - lossfactor)

    push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))
    _atob = if capacity_active
        input = isnothing(atob_availability) && timeseries_mode(s) === :arguments ? 1.0 : atob_availability
        _resolve_timeseries(
            s, input, a.name * ">" * b.name, transfer_sheet;
            keyword="atob_availability", digits=2, lower=0.0, upper=1.0,
        )
    end
    capacity_active && push!(vb, Nosy.CapacityMultiplier("input", _atob))

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - lossfactor)))
    push!(vb, VariableCost(:transaction, "input2", energy, Float64(transactioncost)))
    _btoa = if capacity_active
        input = isnothing(btoa_availability) && timeseries_mode(s) === :arguments ? 1.0 : btoa_availability
        _resolve_timeseries(
            s, input, b.name * ">" * a.name, transfer_sheet;
            keyword="btoa_availability", digits=2, lower=0.0, upper=1.0,
        )
    end
    capacity_active && push!(vb, Nosy.CapacityMultiplier("input2", _btoa))

    # grid losses balance
    # NB when counting grid losses from interconnectors, make sure to not double count losses as interconnectors belong to multiple nodes
    push!(vb, LinkedJointFlow("grid losses ic", b.carrier, :output, ("input", "input2"), x->(x[1]+x[2])*lossfactor, mustconnect=false))

    if _cap isa Real
        input_capacity = gencapacity(
            _cap, "input", s, component_name; mincap=mincap, maxcap=maxcap,
        )
        push!(vb, input_capacity)
        push!(vb, FixedCapacity("input2", energy, _cap))
    else
        _lb = something(mincap, 0.0)
        _ub = something(maxcap, Inf)
        @argcheck _lb >= 0 "Capacity cannot be negative"
        @argcheck _lb <= _ub "Lower bound is bigger than upper bound"
        shared_capacity = if isnothing(_cap)
            variable = @variable(
                Nosy.uppermodel(sim(s)),
                base_name=component_name * "_input_energy_cap_" * sim(s).suffix,
            )
            convert(AffExpr, variable)
        elseif _cap isa VariableRef
            JuMP.check_belongs_to_model(_cap, Nosy.uppermodel(sim(s)))
            convert(AffExpr, _cap)
        else
            _cap
        end
        input_capacity = gencapacity(
            shared_capacity, "input", s, component_name;
            mincap=mincap, maxcap=maxcap,
        )
        reverse_capacity = VariableCapacity(
            "input2", energy;
            expression=input_capacity.expr, lb=_lb, ub=_ub,
        )
        push!(vb, input_capacity)
        push!(vb, reverse_capacity)
    end
    push!(vb, FixedCost(:investment, "input", energy, _inv))
    push!(vb, FixedCost(:fom, "input", energy, _fom * 1000.0))

    c = Component(component_name, m, vb)

    # make the IC flow go in one direction only
    if dir
        flows = balance(c, :input, energy, collapse=false, aggregate=false)
        b1 = flows["input"]
        b2 = flows["input2"]
        for step in eachindex(b1)
            @constraint(Nosy.sim(s).model, [b1[step], b2[step]] in SOS1())
        end
    end
    
    for t in ("interconnection", "nodeinterconnection")
        tag!(c, :function, t)
    end
    dc ? tag!(c, :function, "DC") : tag!(c, :function, "AC") # AC or DC

    connect!(s, c, a)
    connect!(s, c, b)
    # denormalized zone metadata for convenient component queries 
    tag!(c, :zone, a.name)
    tag!(c, :zone, b.name)

    if !dc && !isnothing(susceptance)
        _register_ic_susceptance!(s, a.name, b.name, susceptance)
    end

    return c
end
