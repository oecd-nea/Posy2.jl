"""
Generate interconnection components.
"""

"""
    makepriceinterco(zone::String, elec::Node, mcap, xcap, s::Snapshot;
        dir::Bool=false, foreign::Bool=true,
        transactioncost::Real=0.,
        spot_price=nothing, import_availability=nothing, export_availability=nothing,
    )

Build, connect and return an interconnection component based on a price time series.
If `dir` is true, apply a one direction at a time constraint at every timestep.

Arguments:
  * `zone`: priced counterparty zone name for spot price and transfer capacity time series
  * `elec`: local electricity node to connect the interconnector to.
  * `mcap`: Import capacity as a number, JuMP `VariableRef`, or `AffExpr`.
  * `xcap`: Export capacity as a number, JuMP `VariableRef`, or `AffExpr`.
  * `s`: snapshot to register the component in.

  * `dir`: if `true`, apply SOS1 one direction at a time flow constraint.
  * `foreign`: if `true`, tag interconnector as `:foreign`.

  * `transactioncost`: per unit transaction adder on both directions.
  * `spot_price`: Hourly foreign spot-price vector or scalar.
  * `import_availability`: Hourly multiplier for the foreign-to-local direction,
    each value in `[0, 1]`.
  * `export_availability`: Hourly multiplier for the local-to-foreign direction,
    with the same `[0, 1]` domain.
    Availability is resolved for numeric nonzero and all symbolic directions. When omitted,
    it comes from the workbook in `:excel` mode and defaults to one in
    `:arguments` mode. `spot_price` is required whenever either direction has
    active capacity. When both capacities are numeric zeros the corridor is
    disabled: no spot price is read and the reported exogenous price is an
    hourly series of zeros.
"""
function makepriceinterco(zone::String, elec::Node, mcap::Union{Real,VariableRef,AffExpr}, xcap::Union{Real,VariableRef,AffExpr}, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=true,

    # economic controls
    transactioncost::Real=0.,
    spot_price=nothing, import_availability=nothing, export_availability=nothing,
)
    vb = []
    imports_active = mcap isa Real ? !iszero(mcap) : true
    exports_active = xcap isa Real ? !iszero(xcap) : true
    _imports = if imports_active
        input = isnothing(import_availability) && timeseries_mode(s) === :arguments ? 1.0 : import_availability
        _resolve_timeseries(
            s, input, zone * ">" * elec.name, "transfer_capacities";
            keyword="import_availability", lower=0.0, upper=1.0,
        )
    end
    _exports = if exports_active
        input = isnothing(export_availability) && timeseries_mode(s) === :arguments ? 1.0 : export_availability
        _resolve_timeseries(
            s, input, elec.name * ">" * zone, "transfer_capacities";
            keyword="export_availability", lower=0.0, upper=1.0,
        )
    end
    _spot = if imports_active || exports_active
        _resolve_timeseries(
            s, spot_price, zone, "spot_price"; keyword="spot_price", digits=2,
        )
    else
        # a fully disabled corridor has no price to resolve, but reporting still
        # expects an hourly series
        zeros(Nosy.nhours(sim(s)))
    end

    # imports
    m = DispatchableSource(elec.carrier)
    if mcap isa Real
        push!(vb, FixedCapacity("output", energy, mcap))
    elseif mcap isa VariableRef || mcap isa AffExpr
        JuMP.check_belongs_to_model(mcap, Nosy.uppermodel(sim(s)))
        push!(vb, VariableCapacity("output", energy; expression=mcap))
    end
    imports_active && push!(vb, Nosy.CapacityMultiplier("output", _imports))
    push!(vb, VariableCost(:imports, "output", energy, _spot))
    push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))

    # exports
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    if xcap isa Real
        push!(vb, FixedCapacity("input", energy, xcap))
    elseif xcap isa VariableRef || xcap isa AffExpr
        JuMP.check_belongs_to_model(xcap, Nosy.uppermodel(sim(s)))
        push!(vb, VariableCapacity("input", energy; expression=xcap))
    end
    exports_active && push!(vb, Nosy.CapacityMultiplier("input", _exports))
    push!(vb, VariableCost(:exports, "input", energy, -1 .* _spot))
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
    for t in ("interconnection", "priceinterconnection")
        tag!(c, :function, t)
    end
    if foreign
        tag!(c, :function, "foreign")
    end
    tag!(c, :neighbor, zone)
    connect!(s, c, elec)
    tag!(c, :zone, elec.name)

    return c
end

"""
    makenodeinterco(cname::String, a::Node, b::Node, atob, btoa, s::Snapshot;
        dir::Bool=false, dc::Bool=false,
        transactioncost::Real=0., lossfactor::Real=0.,
        susceptance::Union{Nothing,Real}=nothing,
        atob_availability=nothing, btoa_availability=nothing,
    )

Build, connect and return an interconnection component linking two nodes.
Whether the link crosses the self-system boundary is derived at reporting time
from the connected nodes' `:foreign` tags; there is no component-level flag.

Arguments:
  * `cname`: interconnector name prefix.
  * `a`: first node linked by the interconnector.
  * `b`: distinct second node linked by the interconnector; self-connections
    are rejected before model construction.
  * `atob`: Directional capacity for `a -> b` as a number, JuMP `VariableRef`,
    or `AffExpr` (`Inf` disables the numeric capacity limit).
  * `btoa`: Directional capacity for `b -> a` with the same semantics.
  * `s`: snapshot to register the component in.

  * `dir`: apply an SOS1 one direction at a time flow constraint.
  * `dc`: if `true`, tag as `:DC`; otherwise tag as `:AC`.

  * `transactioncost`: per unit transaction adder on each direction.
  * `lossfactor`: proportional losses applied on conversion; must be finite and
    satisfy `0 <= lossfactor < 1`.
  * `susceptance`: AC susceptance for DC power flow (must be negative); stored in
    `Snapshot.options[:ic_susceptance]` (required for KVL when `Posy2Options.dcopf` is true).
  * `atob_availability`: Hourly `a -> b` multiplier vector or scalar, each value
    in `[0, 1]`.
  * `btoa_availability`: Hourly `b -> a` multiplier vector or scalar, with the
    same `[0, 1]` domain. A finite
    numeric nonzero or symbolic direction reads its workbook column in `:excel`
    mode when omitted, and defaults to one in `:arguments` mode. Numeric zero
    and `Inf` directions do not resolve an availability series.

Node interconnections cannot be added after [`applydcopf!`](@ref) has run on the
snapshot; build the full topology first.

Exactly one `AC` and one `DC` may share the same unordered node pair
(either, both, or neither is fine). A second `AC` or a second `DC` on
that pair raises an error. Component-name collisions are also rejected before
model construction. Aggregate equivalent parallel circuits before calling
this builder.
"""
function makenodeinterco(cname::String, a::Node, b::Node, atob::Union{Real,VariableRef,AffExpr}, btoa::Union{Real,VariableRef,AffExpr}, s::Snapshot;
    # operation flags
    dir::Bool=false, dc::Bool=false,

    # economic / physical controls
    transactioncost::Real=0., lossfactor::Real=0.,
    susceptance::Union{Nothing,Real}=nothing,
    atob_availability=nothing, btoa_availability=nothing,
)
    @argcheck 0 <= lossfactor < 1 "lossfactor must be in [0, 1)"
    component_name = string(cname, "_", a.name, "_", b.name)
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

    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1. - lossfactor)

    push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))
    if !(atob isa Real && atob == Inf)
        if atob isa Real
            push!(vb, FixedCapacity("input", energy, atob))
        elseif atob isa VariableRef || atob isa AffExpr
            JuMP.check_belongs_to_model(atob, Nosy.uppermodel(sim(s)))
            push!(vb, VariableCapacity("input", energy; expression=atob))
        end
        if !(atob isa Real && iszero(atob))
            input = isnothing(atob_availability) && timeseries_mode(s) === :arguments ? 1.0 : atob_availability
            push!(vb, Nosy.CapacityMultiplier("input", _resolve_timeseries(
                s, input, a.name * ">" * b.name, "transfer_capacities";
                keyword="atob_availability", digits=2, lower=0.0, upper=1.0,
            )))
        end
    end

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - lossfactor)))
    push!(vb, VariableCost(:transaction, "input2", energy, Float64(transactioncost)))
    if !(btoa isa Real && btoa == Inf)
        if btoa isa Real
            push!(vb, FixedCapacity("input2", energy, btoa))
        elseif btoa isa VariableRef || btoa isa AffExpr
            JuMP.check_belongs_to_model(btoa, Nosy.uppermodel(sim(s)))
            push!(vb, VariableCapacity("input2", energy; expression=btoa))
        end
        if !(btoa isa Real && iszero(btoa))
            input = isnothing(btoa_availability) && timeseries_mode(s) === :arguments ? 1.0 : btoa_availability
            push!(vb, Nosy.CapacityMultiplier("input2", _resolve_timeseries(
                s, input, b.name * ">" * a.name, "transfer_capacities";
                keyword="btoa_availability", digits=2, lower=0.0, upper=1.0,
            )))
        end
    end

    # grid losses balance
    # NB when counting grid losses from interconnectors, make sure to not double count losses as interconnectors belong to multiple nodes
    push!(vb, LinkedJointFlow("grid losses ic", b.carrier, :output, ("input", "input2"), x->(x[1]+x[2])*lossfactor, mustconnect=false))

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
