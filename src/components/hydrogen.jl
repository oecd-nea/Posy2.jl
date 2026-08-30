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
    annual_supply >= 0 || throw(ArgumentError("annual_supply must be >= 0"))
    m = ProfileSource(n.carrier, 1.)
    vb = []
    push!(vb, FixedCapacity("output", energy, annual_supply/8760))
    c = Component(name * " " * n.name, m, vb)
    tag!(c, :tech, tech)
    tag!(c, :zone, n.name)
    for t in ("hydrogen", "purchase")
        tag!(c, :function, t)
    end
    connect!(s, c, n)
    return c
end
