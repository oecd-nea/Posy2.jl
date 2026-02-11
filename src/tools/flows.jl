"""
Tools for flows.
"""

using Nosy: AbstractComponent, AbstractCapacityBehavior, uniquebehavior, _balance, portsense, PortRef
using ArgCheck: @argcheck

function _unusedcapacity(c::Component, pname::String)
    _cap = Nosy.uniquebehavior(c, AbstractCapacityBehavior)
    m = _cap.data.modifier
    s = portsense(c.s, PortRef(c.name, pname))
    cap = capacity(c, pname, multiplier=true) # capacity with multiplier
    b = _balance(c, pname, s, m, collapse=false) # stepwise balance
    return cap .- b
end


function unusediccapacity(c::Component)
    u1 = _unusedcapacity(c, "input")
    u2 = _unusedcapacity(c, "input2")
    return Dict("input1" => u1, "input2" => u2)
end