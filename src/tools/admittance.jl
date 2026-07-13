"""
Node interconnection admittance (B) registry for DC power flow (KVL).

Values are stored in `Snapshot.options[:ic_admittance]` and registered by
`makenodeinterco` or `register_ic_admittance!`.
"""

function _ic_admittance_registry(s::Snapshot)
    if !haskey(s.options, :ic_admittance)
        s.options[:ic_admittance] = Dict{Tuple{String, String}, Float64}()
    end
    reg = s.options[:ic_admittance]
    reg isa Dict{Tuple{String, String}, Float64} ||
        throw(ArgumentError(":ic_admittance must be Dict{Tuple{String,String},Float64}, got $(typeof(reg))"))
    return reg
end

function register_ic_admittance!(s::Snapshot, from::String, to::String, bij::Number)
    @argcheck bij > 0 "admittance must be positive"
    _ic_admittance_registry(s)[(from, to)] = Float64(bij)
    return nothing
end

function ic_admittance(s::Snapshot, from::String, to::String)
    reg = _ic_admittance_registry(s)
    if haskey(reg, (from, to))
        return reg[(from, to)]
    elseif haskey(reg, (to, from))
        return reg[(to, from)]
    else
        throw(ArgumentError("No admittance registered for node IC $from - $to"))
    end
end
