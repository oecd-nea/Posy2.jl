"""
Hydrogen supply and related helpers.
"""

"""
    makeflathydrogenpurchase(cname::String, n::Node, val::Number, s::Snapshot)

Build, connect and return a flat hydrogen purchase component.

Arguments:
  * `cname`: component name prefix.
  * `n`: hydrogen node to connect the component to.
  * `val`: yearly purchased hydrogen amount, converted internally to a flat hourly capacity (`val / 8760`).
  * `s`: snapshot to register the component in.
"""
function makeflathydrogenpurchase(cname::String, n::Node, val::Number, s::Snapshot)
    m = ProfileSource(n.carrier, 1.)
    vb = []
    push!(vb, FixedCapacity("output", energy, val/8760))
    c = Component(cname * " " * n.name, m, vb)
    tag!(c, :tech, cname)
    tag!(c, :zone, n.name)
    for t in ("hydrogen", "purchase")
        tag!(c, :function, t)
    end
    connect!(s, c, n)
    return c
end
