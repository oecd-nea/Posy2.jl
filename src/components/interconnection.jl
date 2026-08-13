"""
Generate interconnection components.
"""

"""
    makepriceinterco(zone::String, elec::Node, mcap::Real, xcap::Real, s::Snapshot;
        dir::Bool=false, foreign::Bool=true,
        transactioncost::Real=0.,
        spot_price=nothing, import_availability=nothing, export_availability=nothing,
    )

Build, connect and return an interconnection component based on a price time series.
If `dir` is true, apply a one direction at a time constraint at every timestep.

Arguments:
  * `zone`: priced counterparty zone name for spot price and transfer capacity time series
  * `elec`: local electricity node to connect the interconnector to.
  * `mcap`: import side fixed capacity.
  * `xcap`: export side fixed capacity.
  * `s`: snapshot to register the component in.

  * `dir`: if `true`, apply SOS1 one direction at a time flow constraint.
  * `foreign`: if `true`, tag interconnector as `:foreign`.

  * `transactioncost`: per unit transaction adder on both directions.
  * `spot_price`: Hourly foreign spot-price vector or scalar.
  * `import_availability`: Hourly multiplier for the foreign-to-local direction.
  * `export_availability`: Hourly multiplier for the local-to-foreign direction.
    Availability is resolved only for nonzero-capacity directions. When omitted,
    it comes from the workbook in `:excel` mode and defaults to one in
    `:arguments` mode. `spot_price` is required whenever either direction has
    nonzero capacity.
"""
function makepriceinterco(zone::String, elec::Node, mcap::Real, xcap::Real, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=true,

    # economic controls
    transactioncost::Real=0.,
    spot_price=nothing, import_availability=nothing, export_availability=nothing,
)
    vb = []
    imports_active = !iszero(mcap)
    exports_active = !iszero(xcap)
    _imports = if imports_active
        input = isnothing(import_availability) && timeseries_mode(s) === :arguments ? 1.0 : import_availability
        _resolve_timeseries(
            s, input, zone * ">" * elec.name, "transfer_capacities";
            keyword="import_availability",
        )
    end
    _exports = if exports_active
        input = isnothing(export_availability) && timeseries_mode(s) === :arguments ? 1.0 : export_availability
        _resolve_timeseries(
            s, input, elec.name * ">" * zone, "transfer_capacities";
            keyword="export_availability",
        )
    end
    _spot = if imports_active || exports_active
        _resolve_timeseries(
            s, spot_price, zone, "spot_price"; keyword="spot_price", digits=2,
        )
    else
        0.0
    end

    # imports
    m = DispatchableSource(elec.carrier)
    push!(vb, FixedCapacity("output", energy, mcap))
    imports_active && push!(vb, Nosy.CapacityMultiplier("output", _imports))
    push!(vb, VariableCost(:imports, "output", energy, _spot))
    push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))

    # exports
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, FixedCapacity("input", energy, xcap))
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
    makenodeinterco(cname::String, a::Node, b::Node, atob::Real, btoa::Real, s::Snapshot;
        dir::Bool=false, foreign::Bool=false, dc::Bool=false,
        transactioncost::Real=0., lossfactor::Real=0.,
        susceptance::Union{Nothing,Real}=nothing,
        atob_availability=nothing, btoa_availability=nothing,
    )

Build, connect and return an interconnection component linking two nodes.

Arguments:
  * `cname`: interconnector name prefix.
  * `a`: first node linked by the interconnector.
  * `b`: distinct second node linked by the interconnector; self-connections
    are rejected before model construction.
  * `atob`: directional capacity for `a -> b` (`Inf` disables capacity limit).
  * `btoa`: directional capacity for `b -> a` (`Inf` disables capacity limit).
  * `s`: snapshot to register the component in.

  * `dir`: apply an SOS1 one direction at a time flow constraint.
  * `foreign`: if `true`, tag interconnector as `:foreign`.
  * `dc`: if `true`, tag as `:DC`; otherwise tag as `:AC`.

  * `transactioncost`: per unit transaction adder on each finite-capacity
    direction.
  * `lossfactor`: proportional losses applied on conversion; must be finite and
    satisfy `0 <= lossfactor < 1`.
  * `susceptance`: AC susceptance for DC power flow (must be negative); stored in
    `Snapshot.options[:ic_susceptance]` (required for KVL when `Posy2Options.dcopf` is true).
  * `atob_availability`: Hourly `a -> b` multiplier vector or scalar.
  * `btoa_availability`: Hourly `b -> a` multiplier vector or scalar. A finite
    nonzero direction reads its workbook column in `:excel` mode when omitted,
    and defaults to one in `:arguments` mode. Zero- and infinite-capacity
    directions do not resolve an availability series.

Exactly one `AC` and one `DC` may share the same unordered node pair
(either, both, or neither is fine). A second `AC` or a second `DC` on
that pair raises an error. Component-name collisions are also rejected before
model construction. Aggregate equivalent parallel circuits before calling
this builder.
"""
function makenodeinterco(cname::String, a::Node, b::Node, atob::Real, btoa::Real, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=false, dc::Bool=false,

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
    if !isinf(atob)
        push!(vb, FixedCapacity("input", energy, atob))
        if !iszero(atob)
            input = isnothing(atob_availability) && timeseries_mode(s) === :arguments ? 1.0 : atob_availability
            push!(vb, Nosy.CapacityMultiplier("input", _resolve_timeseries(
                s, input, a.name * ">" * b.name, "transfer_capacities";
                keyword="atob_availability", digits=2,
            )))
        end
    end

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - lossfactor)))
    push!(vb, VariableCost(:transaction, "input2", energy, Float64(transactioncost)))
    if !isinf(btoa)
        push!(vb, FixedCapacity("input2", energy, btoa))
        if !iszero(btoa)
            input = isnothing(btoa_availability) && timeseries_mode(s) === :arguments ? 1.0 : btoa_availability
            push!(vb, Nosy.CapacityMultiplier("input2", _resolve_timeseries(
                s, input, b.name * ">" * a.name, "transfer_capacities";
                keyword="btoa_availability", digits=2,
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
    foreign && tag!(c, :function, "foreign") # IC between self and other country
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
