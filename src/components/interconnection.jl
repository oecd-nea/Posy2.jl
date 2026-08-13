"""
Generate interconnection components.
"""

"""
    makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot;
        dir::Bool=false, foreign::Bool=true,
        transactioncost::Number=0.,
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
    Each series falls back to its workbook column when `nothing`.
"""
function makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=true,

    # economic controls
    transactioncost::Number=0.,
    spot_price=nothing, import_availability=nothing, export_availability=nothing,
)
    vb = []
    _imports = _resolve_timeseries(
        s, import_availability, zone * ">" * elec.name, "transfer_capacities";
        keyword="import_availability",
    )
    _exports = _resolve_timeseries(
        s, export_availability, elec.name * ">" * zone, "transfer_capacities";
        keyword="export_availability",
    )
    _spot = _resolve_timeseries(
        s, spot_price, zone, "spot_price"; keyword="spot_price", digits=2,
    )

    # imports
    m = DispatchableSource(elec.carrier)
    push!(vb, FixedCapacity("output", energy, mcap))
    push!(vb, Nosy.CapacityMultiplier("output", _imports))
    push!(vb, VariableCost(:imports, "output", energy, _spot))
    push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))

    # exports
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, FixedCapacity("input", energy, xcap))
    push!(vb, Nosy.CapacityMultiplier("input", _exports))
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
    makenodeinterco(cname::String, a::Node, b::Node, atob::Number, btoa::Number, s::Snapshot;
        dir::Bool=false, foreign::Bool=false, dc::Bool=false,
        transactioncost::Number=0., lossfactor::Number=0.,
        susceptance::Union{Nothing,Number}=nothing,
        atob_availability=nothing, btoa_availability=nothing,
    )

Build, connect and return an interconnection component linking two nodes.

Arguments:
  * `cname`: interconnector name prefix.
  * `a`: first node linked by the interconnector.
  * `b`: second node linked by the interconnector.
  * `atob`: directional capacity for `a -> b` (`Inf` disables capacity limit).
  * `btoa`: directional capacity for `b -> a` (`Inf` disables capacity limit).
  * `s`: snapshot to register the component in.

  * `dir`: apply an SOS1 one direction at a time flow constraint.
  * `foreign`: if `true`, tag interconnector as `:foreign`.
  * `dc`: if `true`, tag as `:DC`; otherwise tag as `:AC`.

  * `transactioncost`: per unit transaction adder on each finite-capacity
    direction.
  * `lossfactor`: proportional losses applied on conversion.
  * `susceptance`: AC susceptance for DC power flow (must be negative); stored in
    `Snapshot.options[:ic_susceptance]` (required for KVL when `Posy2Options.dcopf` is true).
  * `atob_availability`: Hourly `a -> b` multiplier vector or scalar.
  * `btoa_availability`: Hourly `b -> a` multiplier vector or scalar. A finite
    direction falls back to its workbook column when the keyword is `nothing`.

Exactly one `AC` and one `DC` may share the same unordered node pair
(either, both, or neither is fine). A second `AC` or a second `DC` on
that pair raises an error. Aggregate equivalent parallel circuits
before calling this builder.
"""
function makenodeinterco(cname::String, a::Node, b::Node, atob::Number, btoa::Number, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=false, dc::Bool=false,

    # economic / physical controls
    transactioncost::Number=0., lossfactor::Number=0.,
    susceptance::Union{Nothing,Number}=nothing,
    atob_availability=nothing, btoa_availability=nothing,
)
    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1. - lossfactor)

    push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))
    if !isinf(atob)
        push!(vb, FixedCapacity("input", energy, atob))
        push!(vb, Nosy.CapacityMultiplier("input", _resolve_timeseries(
            s, atob_availability, a.name * ">" * b.name, "transfer_capacities";
            keyword="atob_availability", digits=2,
        )))
    end

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - lossfactor)))
    push!(vb, VariableCost(:transaction, "input2", energy, Float64(transactioncost)))
    if !isinf(btoa)
        push!(vb, FixedCapacity("input2", energy, btoa))
        push!(vb, Nosy.CapacityMultiplier("input2", _resolve_timeseries(
            s, btoa_availability, b.name * ">" * a.name, "transfer_capacities";
            keyword="btoa_availability", digits=2,
        )))
    end

    # grid losses balance
    # NB when counting grid losses from interconnectors, make sure to not double count losses as interconnectors belong to multiple nodes
    push!(vb, LinkedJointFlow("grid losses ic", b.carrier, :output, ("input", "input2"), x->(x[1]+x[2])*lossfactor, mustconnect=false))

    c = Component(string(cname, "_", a.name, "_", b.name), m, vb)

    # make the IC flow go in one direction only
    if dir
        b = balance(c, :input, energy, collapse=false, aggregate=false)
        b1 = b["input"]
        b2 = b["input2"]
        for step in eachindex(b1)
            @constraint(Nosy.sim(s).model, [b1[step], b2[step]] in SOS1())
        end
    end
    
    for t in ("interconnection", "nodeinterconnection")
        tag!(c, :function, t)
    end
    foreign && tag!(c, :function, "foreign") # IC between self and other country
    dc ? tag!(c, :function, "DC") : tag!(c, :function, "AC") # AC or DC

    # One AC and one DC may share a pair; a second AC or second DC is rejected.
    pair = Set([a.name, b.name])
    for (_, existing) in getcomponents(s; with=[:function => "nodeinterconnection"])
        same_pair = Set(get(existing.tags, :zone, String[])) == pair
        same_pair || continue
        existing_dc = hastag(existing, :function, "DC")
        if existing_dc == dc
            kind = dc ? "DC" : "AC"
            throw(ArgumentError("a $kind node interconnection already exists between $(a.name) and $(b.name); parallel $kind ICs are not supported"))
        end
    end

    if !dc && !isnothing(susceptance)
        _register_ic_susceptance!(s, a.name, b.name, susceptance)
    end

    connect!(s, c, a)
    connect!(s, c, b)
    # denormalized zone metadata for convenient component queries 
    tag!(c, :zone, a.name)
    tag!(c, :zone, b.name)

    return c
end
