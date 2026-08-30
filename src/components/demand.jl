"""
Generate demand-side components.
"""

using ArgCheck: @argcheck

"""
    makedemand(name::String, zone::String, n::Node, s::Snapshot;
        tech::String=name, profile=nothing, coeff=1.0, shift::Int=0,
        yearlyconstant::Real=0., gridlosses=0.,
    )

Build, connect and return a component based on the Demand template.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `zone`: time series name in the time series workbook (`demand` sheet).
  * `n`: demand node to connect the component to.
  * `s`: snapshot to register the component in.
  * `profile`: Hourly demand in MW, or a scalar expanded across the simulation
    mesh. If `nothing`, read `zone` from the `demand` sheet.
  * `coeff`: Dimensionless multiplier applied to the profile demand. `0`
    disables it and skips the `zone`, `profile`, and `shift` inputs.
  * `shift`: Circular profile shift in time steps (e.g. align the first day to
    Monday).
  * `yearlyconstant`: Flat demand in MWh/year, distributed over 8760 hours
    (`yearlyconstant >= 0`).
  * `gridlosses`: Proportional grid-loss fraction on demand input
    (`0 <= gridlosses < 1`).
"""
function makedemand(name::String, zone::String, n::Node, s::Snapshot;
                    tech::String=name, profile=nothing, coeff::Real=1.0, shift::Int=0,
                    yearlyconstant::Real=0., gridlosses::Real=0.)
    inputs = demand_input(coeff=coeff, yearlyconstant=yearlyconstant, gridlosses=gridlosses)
    validate_demand_input(inputs)
    _gridlosses = Float64(gridlosses)
    if iszero(coeff)
        var = 0.
    else
        var = coeff * _resolve_timeseries(s, profile, zone, "demand"; keyword="profile")
        var = circshift(var, shift)
    end

    m = Demand(n.carrier, (var .+ yearlyconstant / 8760))
    vb = []
    !iszero(_gridlosses) && push!(vb, LinkedJointFlow("grid losses", n.carrier, :input, "input", x->x[1] * _gridlosses))
    c = Component(name * " " * n.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, n.name)
    for t in ("electricity", "demand")
        tag!(c, :function, t)
    end
    connect!(s, c, n)   
    return c
end

"""
    makeflathydrogendemand(name::String, n::Node, val::Real, s::Snapshot;
        tech::String=name)

Build, connect and return a flat hydrogen demand component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `n`: hydrogen demand node to connect the component to.
  * `val`: Total hydrogen demand in MWh/year. Must satisfy `val >= 0`.
  * `s`: snapshot to register the component in.
"""
function makeflathydrogendemand(name::String, n::Node, val::Real, s::Snapshot;
    tech::String=name,
)
    inputs = demand_input(val=val)
    validate_demand_input(inputs)
    m = Demand(n.carrier, val / 8760)
    vb = []
    c = Component(name * " " * n.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, n.name)
    for t in ("hydrogen", "demand")
        tag!(c, :function, t)
    end
    connect!(s, c, n)
    return c
end

"""
    makeflexhydrogendemand(name::String, n::Node, val::Real, s::Snapshot;
        tech::String=name)

Build, connect and return a flexible hydrogen demand component.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `n`: hydrogen demand node to connect the component to.
  * `val`: Total hydrogen demand in MWh/year, enforced through
    `YearlySum("input", val, :equal)`. Must satisfy `val >= 0`.
  * `s`: snapshot to register the component in.
"""
function makeflexhydrogendemand(name::String, n::Node, val::Real, s::Snapshot;
    tech::String=name,
)
    inputs = demand_input(val=val)
    validate_demand_input(inputs)
    m = BasicSink(n.carrier)
    vb = []
    push!(vb, YearlySum("input", val, :equal))
    c = Component(name * " " * n.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, n.name)
    for t in ("hydrogen", "demand")
        tag!(c, :function, t)
    end
    connect!(s, c, n)
    return c
end

"""
    makedemandresponse(name::String, elec::Node, cap, cost::Real, s::Snapshot;
        tech::String=name, type::Symbol=:volDR)

Build, connect and return a demand response component represented as negative
consumption.

The positive `output` is an unconnected accounting flow used for capacity,
cost, and reporting. The connected `negative consumption` input is
`-(1 - elec.losses) * output`; when node losses are zero, it is exactly
`-output`. Consequently, activation enters the nodal balance on the demand
side without modifying existing demand components.

Arguments:
  * `name`: component name prefix.
  * `tech`: technology label used for reporting; defaults to `name`.
  * `elec`: electricity node to connect the component to.
  * `cap`: Response capacity in MW. A number fixes capacity, a JuMP
    `VariableRef` or `AffExpr` reuses that expression, `nothing` creates a
    capacity decision, and `Inf` leaves output unlimited. `nothing` emits a
    warning to distinguish it from unlimited capacity.
  * `cost`: Activation cost in currency/MWh.
  * `s`: snapshot to register the component in.
  * `type`: variable cost label used for reporting (default `:volDR`).
"""
function makedemandresponse(name::String, elec::Node, cap::Union{Nothing,Real,VariableRef,AffExpr}, cost::Real, s::Snapshot;
    tech::String=name, type::Symbol=:volDR,
)
    # Demand provides a zero-valued input that anchors this demand-side
    # component. `output` remains positive for capacity, cost, and reporting,
    # but is not connected to the electricity node. Only its negative linked
    # input participates in the nodal balance.
    m = Demand(elec.carrier, 0.0)
    vb = Any[
        FreeJointFlow("output", elec.carrier, :output; mustconnect=false),
        LinkedJointFlow("negative consumption", elec.carrier, :input, "output", x -> -x[1] * (1 - elec.losses)),
    ]
    if isnothing(cap)
        @warn "`cap=nothing` defines a variable demand response capacity. Use `cap=Inf` for unlimited capacity."
    end
    if !(cap isa Real && cap == Inf)
        push!(vb, gencapacity(cap, "output", s, name * " " * elec.name))
    end
    push!(vb, VariableCost(type, "output", energy, cost))

    c = Component(name * " " * elec.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, elec.name)
    for t in ("virtual", "demandresponse")
        tag!(c, :function, t)
    end
    connect!(s, c, elec)
    return c
end
