"""
Hydrogen supply and related helpers.
"""

"""
    makeflathydrogenpurchase(name::String, n::Node, annual_supply::Real, s::Snapshot;
        tech::String=name)

Build, connect and return a flat hydrogen purchase component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting and component queries; defaults to `name`.
  * `n`: hydrogen node to connect the component to.
  * `annual_supply`: Purchased hydrogen in MWh/year, converted internally to a flat
    hourly flow (`annual_supply / 8760`).
  * `s`: snapshot to register the component in.
"""
function makeflathydrogenpurchase(name::String, n::Node, annual_supply::Real, s::Snapshot;
    tech::String=name,
)
    checkhorizon(s)
    annual_supply >= 0 || throw(ArgumentError("annual_supply must be >= 0"))
    m = ProfileSource(n.carrier, 1.)
    vb = []
    push!(vb, FixedCapacity("output", energy, annual_supply / HOURS_PER_YEAR))
    c = Component(name * " " * n.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, n.name)
    for t in ("hydrogen", "purchase")
        tag!(c, :function, t)
    end
    connect!(s, c, n)
    return c
end


"""
    makehydrogentransport(name::String, a::Node, b::Node, s::Snapshot;
        cap=nothing, mincap=nothing, maxcap=nothing,
        exclusive_direction::Bool=false,
        loss_factor::Real=0., transaction_cost::Real=0.,
        overnight_cost=nothing, om_fixed_cost=nothing,
        lifetime=nothing, construction_profile=nothing,
        elec_a=nothing, elec_b=nothing, electricity_coeff::Real=0.,
    )

Build, connect and return a hydrogen transport link between nodes `a` and `b`.

Arguments:
  * `name`: component name prefix.
  * `a`: first hydrogen node linked by the transport corridor.
  * `b`: distinct second hydrogen node linked by the transport corridor;
    self-connections are rejected before model construction.
  * `s`: snapshot to register the component in.

  * `cap`: Installed send capacity in MW shared by both directions. A number fixes
    capacity, a JuMP `VariableRef` or `AffExpr` reuses that expression,
    `nothing` creates a capacity decision, and an extracted `Snapshot` inherits
    the capacity of `"<name>_<a.name>_<b.name>"` on port `input`. Numeric `0`
    builds a zero-capacity corridor.
  * `mincap`: Lower capacity bound in MW; checked as an assertion against a fixed
    or inherited one.
  * `maxcap`: Upper capacity bound in MW; checked as an assertion against a fixed
    or inherited one.

  * `exclusive_direction`: apply an SOS1 one direction at a time flow constraint.
  * `loss_factor`: Dimensionless proportional send-side loss; must satisfy
    `0 <= loss_factor < 1`. Receive flows use `(1 - loss_factor)`. The unconnected
    `hydrogen transport losses` output records `loss_factor * (input + input2)` for
    reporting.
  * `transaction_cost`: Transaction adder in currency/MWh on each send flow
    (`input` and `input2`).

  * `overnight_cost`: Overnight CAPEX in currency/kW of shared corridor capacity.
    Defaults to zero.
  * `om_fixed_cost`: Fixed O&M in currency/kW/year of shared capacity.
    Defaults to zero.
  * `lifetime`: Asset lifetime in years, used to annualize nonzero overnight cost
    (`> 0`, integer-valued).
  * `construction_profile`: Dimensionless yearly construction-cost shares, required
    when `overnight_cost` is nonzero.

  * `elec_a`: optional electricity node for compressor power on the `a -> b` send
    flow (`electricity_a` port).
  * `elec_b`: optional electricity node for compressor power on the `b -> a` send
    flow (`electricity_b` port).
  * `electricity_coeff`: compressor electricity consumption in MWh of electricity
    per MWh of hydrogen sent on each connected direction; requires `elec_a` or
    `elec_b` when positive.
"""
function makehydrogentransport(name::String, a::Node, b::Node, s::Snapshot;
    # capacity / expansion
    cap::Union{Nothing,Real,VariableRef,AffExpr,Snapshot}=nothing,
    mincap::Union{Nothing,Real}=nothing, maxcap::Union{Nothing,Real}=nothing,

    # operation flags
    exclusive_direction::Bool=false,

    # economic / physical controls
    loss_factor::Real=0., transaction_cost::Real=0.,
    elec_a::Union{Nothing,Node}=nothing, elec_b::Union{Nothing,Node}=nothing,
    electricity_coeff::Real=0.,

    # economic controls
    overnight_cost::Union{Nothing,Real}=nothing,
    om_fixed_cost::Union{Nothing,Real}=nothing,
    lifetime::Union{Nothing,Real}=nothing,
    construction_profile=nothing,
)
    checkhorizon(s)
    @argcheck 0 <= loss_factor < 1 "loss_factor must be in [0, 1)"
    @argcheck electricity_coeff >= 0 "electricity_coeff must be >= 0"
    @argcheck iszero(electricity_coeff) || !isnothing(elec_a) || !isnothing(elec_b) ("elec_a or elec_b is required when electricity_coeff is positive")
    component_name = string(name, "_", a.name, "_", b.name)
    a.name == b.name && throw(ArgumentError("hydrogen transport must connect two distinct nodes"))
    Nosy.hascomponent(s, component_name) && throw(ArgumentError("snapshot already has a component named $component_name"))
    Nosy.hasnode(s, component_name) && throw(ArgumentError("snapshot already has a node named $component_name"))

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
        _oc_raw * 1000.0, discount_rate(s), Int(_lt_raw), _cp,
    )

    _electricity_coeff = Float64(electricity_coeff)

    # A hydrogen transport corridor has one installed capacity. Both capacity
    # behaviors below reuse the same value or AffExpr.
    _cap = cap isa Snapshot ? _inheritedcapacity(cap, component_name, "input", "cap") : cap

    vb = []

    # a -> b
    m = BasicConverter(a.carrier, b.carrier, ratio=1. - loss_factor)

    push!(vb, VariableCost(:transaction, "input", energy, Float64(transaction_cost)))

    # b -> a
    push!(vb, FreeJointFlow("input2", b.carrier, :input))
    push!(vb, LinkedJointFlow("output2", a.carrier, :output, "input2", x->x[1] * (1. - loss_factor)))
    push!(vb, VariableCost(:transaction, "input2", energy, Float64(transaction_cost)))

    # compressor electricity (optional)
    if !isnothing(elec_a) && !iszero(electricity_coeff)
        push!(vb, LinkedJointFlow("electricity_a", elec_a.carrier, :input, "input", x -> x[1] * electricity_coeff,))
    end
    if !isnothing(elec_b) && !iszero(electricity_coeff)
        push!(vb, LinkedJointFlow("electricity_b", elec_b.carrier, :input, "input2", x -> x[1] * electricity_coeff,))
    end

    # transport losses balance
    # NB when counting hydrogen transport losses, make sure to not double count losses as transport corridors belong to multiple nodes
    push!(vb, LinkedJointFlow("hydrogen transport losses", b.carrier, :output, ("input", "input2"), x -> (x[1] + x[2]) * loss_factor, mustconnect=false,))

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

    # make the corridor flow go in one direction only
    if exclusive_direction
        flows = balance(c, :input, energy, collapse=false, aggregate=false)
        b1 = flows["input"]
        b2 = flows["input2"]
        for step in eachindex(b1)
            @constraint(Nosy.sim(s).model, [b1[step], b2[step]] in SOS1())
        end
    end

    for t in ("hydrogen", "transport")
        tag!(c, :function, t)
    end
    tag!(c, :zone, a.name)
    tag!(c, :zone, b.name)

    connect!(s, c, a)
    connect!(s, c, b)
    if !isnothing(elec_a) && !iszero(electricity_coeff)
        connect!(s, c, elec_a)
    end
    if !isnothing(elec_b) && !iszero(electricity_coeff)
        connect!(s, c, elec_b)
    end
    return c
end