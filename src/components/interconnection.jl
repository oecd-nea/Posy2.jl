"""
Generate interconnection components.
"""

"""
    makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot;
        dir::Bool=false, foreign::Bool=true,
        transactioncost::Number=0.,
    )

Build, connect and return an interconnection component based on a price time series.
If `dir` is true, apply a one way constraint at every timestep.

Arguments:
  * zone: priced counterparty zone name for spot price and transfer capacity time series
  * elec: local electricity node to connect the interconnector to.
  * mcap: import side fixed capacity.
  * xcap: export side fixed capacity.
  * s: snapshot to register the component in.

  * dir: if `true`, apply SOS1 one direction at a time flow constraint.
  * foreign: if `true`, tag interconnector as `:foreign`.

  * transactioncost: per unit transaction adder on both directions.
"""
function makepriceinterco(zone::String, elec::Node, mcap::Number, xcap::Number, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=true,

    # economic controls
    transactioncost::Number=0.,
)
    vb = []

    # imports
    m = DispatchableSource(elec.carrier)
    push!(vb, FixedCapacity("output", energy, mcap))
    push!(vb, Nosy.CapacityMultiplier("output", gettimeseries(s, zone * ">" * elec.name, "transfer_capacities")))
    push!(vb, VariableCost(:imports, "output", energy, Float64.(gettimeseries(s, zone, "spot_price", digits=2))))
    push!(vb, VariableCost(:transaction, "output", energy, Float64(transactioncost)))

    # exports
    push!(vb, FreeJointFlow("input", elec.carrier, :input))
    push!(vb, FixedCapacity("input", energy, xcap))
    push!(vb, Nosy.CapacityMultiplier("input", gettimeseries(s, elec.name * ">" * zone, "transfer_capacities")))
    push!(vb, VariableCost(:exports, "input", energy, -1 * Float64.(gettimeseries(s, zone, "spot_price", digits=2))))
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
    )

Build, connect and return an interconnection component linking two nodes.
If `dir` is true, apply a one way constraint at every timestep.

Arguments:
  * cname: interconnector name prefix.
  * a: first node linked by the interconnector.
  * b: second node linked by the interconnector.
  * atob: directional capacity for `a -> b` (`Inf` disables capacity limit).
  * btoa: directional capacity for `b -> a` (`Inf` disables capacity limit).
  * s: snapshot to register the component in.

  * dir: if `true`, apply SOS1 one direction at a time flow constraint.
  * foreign: if `true`, tag interconnector as `:foreign`.
  * dc: if `true`, tag as `:DC`; otherwise tag as `:AC`.

  * transactioncost: per unit transaction adder on both directions.
  * lossfactor: proportional losses applied on conversion.
  * susceptance: AC susceptance for DC power flow (must be negative); stored in
    `Snapshot.options[:ic_susceptance]` (required for KVL when `POSY2Options.dcopf` is true).
"""
function makenodeinterco(cname::String, a::Node, b::Node, atob::Number, btoa::Number, s::Snapshot;
    # operation flags
    dir::Bool=false, foreign::Bool=false, dc::Bool=false,

    # economic / physical controls
    transactioncost::Number=0., lossfactor::Number=0.,
    susceptance::Union{Nothing,Number}=nothing,
)
    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1. - lossfactor)
    
    if !isinf(atob)
        push!(vb, FixedCapacity("input", energy, atob))
        push!(vb, Nosy.CapacityMultiplier("input", gettimeseries(s, a.name * ">" * b.name, "transfer_capacities", digits=2)))
        push!(vb, VariableCost(:transaction, "input", energy, Float64(transactioncost)))
    end

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - lossfactor)))
    if !isinf(btoa)
        push!(vb, FixedCapacity("input2", energy, btoa))
        push!(vb, Nosy.CapacityMultiplier("input2", gettimeseries(s, b.name * ">" * a.name, "transfer_capacities", digits=2)))
        push!(vb, VariableCost(:transaction, "input2", energy, Float64(transactioncost)))
    end

    # grid losses balance
    # NB when counting grid losses from interconnectors, make sure to not double count losses as interconnectors belong to multiple nodes
    push!(vb, LinkedJointFlow("grid losses ic", b.carrier, :output, ("input", "input2"), x->(x[1]+x[2])*lossfactor, mustconnect=false))

    c = Component(string(cname, "_", a.name, "_", b.name), m, vb)

    # make the IC flow go in one direction only
    if dir
        bin = balance(c, :input, energy, collapse=false, aggregate=true)
        bout = balance(c, :output, energy, collapse=false, aggregate=true)
        for step in eachindex(bin)
            @constraint(Nosy.sim(s).model, [bin[step], bout[step]] in SOS1())
        end
    end
    
    for t in ("interconnection", "nodeinterconnection")
        tag!(c, :function, t)
    end
    foreign && tag!(c, :function, "foreign") # IC between self and other country
    dc ? tag!(c, :function, "DC") : tag!(c, :function, "AC") # AC or DC
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
