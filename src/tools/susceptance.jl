"""
Node interconnection susceptance (B) registry for DC power flow (KVL).

Values are stored in `Snapshot.options[:ic_susceptance]` and registered by
`makenodeinterco` (not as a separate public registration API).
"""

function _ic_susceptance_registry(s::Snapshot)
    if !haskey(s.options, :ic_susceptance)
        s.options[:ic_susceptance] = Dict{Tuple{String, String}, Float64}()
    end
    reg = s.options[:ic_susceptance]
    reg isa Dict{Tuple{String, String}, Float64} ||
        throw(ArgumentError(":ic_susceptance must be Dict{Tuple{String,String},Float64}, got $(typeof(reg))"))
    return reg
end

# Internal: only called from `makenodeinterco`.
function _register_ic_susceptance!(s::Snapshot, from::String, to::String, bij::Number)
    @argcheck bij < 0 "susceptance must be negative"
    _ic_susceptance_registry(s)[(from, to)] = Float64(bij)
    return nothing
end

function ic_susceptance(s::Snapshot, from::String, to::String)
    reg = _ic_susceptance_registry(s)
    if haskey(reg, (from, to))
        return reg[(from, to)]
    elseif haskey(reg, (to, from))
        return reg[(to, from)]
    else
        throw(ArgumentError("No susceptance registered for node IC $from - $to"))
    end
end
