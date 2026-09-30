"""
Node interconnection susceptance (B) and optional phase-shift registries for DC power flow (KVL).

Values are stored in `Snapshot.options[:ic_susceptance]` and `:ic_phase_shift` and
registered by `maketransmissionlink` (not as a separate public registration API).
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

# Internal: only called from `maketransmissionlink`.
function _register_ic_susceptance!(s::Snapshot, from::String, to::String, bij::Real)
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

function _ic_phase_shift_registry(s::Snapshot)
    if !haskey(s.options, :ic_phase_shift)
        s.options[:ic_phase_shift] = Dict{Tuple{String, String}, Nosy.Stepwise}()
    end
    reg = s.options[:ic_phase_shift]
    reg isa Dict{Tuple{String, String}, Nosy.Stepwise} ||
        throw(ArgumentError(":ic_phase_shift must be Dict{Tuple{String,String},Stepwise}, got $(typeof(reg))"))
    return reg
end

# Internal: only called from `maketransmissionlink`.
function _register_ic_phase_shift!(s::Snapshot, from::String, to::String, phi::Nosy.Stepwise)
    _ic_phase_shift_registry(s)[(from, to)] = phi
    return nothing
end

function ic_phase_shift(s::Snapshot, from::String, to::String)
    reg = get(s.options, :ic_phase_shift, nothing)
    reg isa Dict{Tuple{String, String}, Nosy.Stepwise} || return nothing
    if haskey(reg, (from, to))
        return reg[(from, to)]
    elseif haskey(reg, (to, from))
        return -reg[(to, from)]
    end
    return nothing
end
