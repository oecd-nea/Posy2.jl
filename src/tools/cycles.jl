"""
Analyze cycles in the interconnection graph.
Goal: Kirchoff voltage law.
"""

using DataFrames
using Graphs
using JuMP

function getintercocapacitymatrix(s::Snapshot)
    allcomps_int = Set{String}()
    allcomps_ext = Set{String}()
    allquasinodes = Set{String}()
    allnodes = getnodes(s, with=[:electricity])
    for (nodename, _) in allnodes
        let d = getcomponents(s, nodename, with=[:interconnection, :nodeinterconnection], without=[:DC,])
            lcomps = [replace(k, (" " * nodename) => "") for (k,_) in d]
            for cname in lcomps
                push!(allcomps_int, cname)
            end
        end
    end

    allquasinodes = vcat(sort(collect(keys(allnodes)))..., sort(collect(allquasinodes))...)    
    df = DataFrame([name => [] for name in vcat(["To \\ From"], allquasinodes)])

    df = DataFrame("From \\ To" => allquasinodes)
    for k in allquasinodes
        df[!,k] = convert(Vector{Union{String,Float64}}, fill(-Inf, length(allquasinodes)))
    end

    for cname in allcomps_int
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_internal(s, c)
        df[df[!,"From \\ To"] .== _from, _to] .= capacity(c, "input") / 1E3
        df[df[!,"From \\ To"] .== _to, _from] .= capacity(c, "input2") / 1E3
    end

    for cname in allcomps_ext
        c = Nosy.getcomponent(s, cname)
        (_from, _to) = _fromto_ic_external(s, c)
        df[df[!,"From \\ To"] .== _from, _to] .= capacity(c, "output") / 1E3
        df[df[!,"From \\ To"] .== _to, _from] .= capacity(c, "input") / 1E3
    end

    return df
end

# generate the cycles basis of the undirected graph
function gencycles(df::DataFrame)
    nodenames = df[!,"From \\ To"]

    # edges of the undirected graph
    edges = Vector{Tuple{Int64,Int64}}(undef,0)
    for i in eachindex(nodenames)
        for j in eachindex(nodenames)
            if j > i
                if !isinf(df[i,j+1])
                    push!(edges, (i,j))
                end
            end            
        end
    end

    # generate the undirected graph
    g = SimpleGraph(Graphs.SimpleEdge.(edges))



    # generate the cycle basis of the undirected graph
    b = cycle_basis(g)

    # reassign name to nodes
    namedcycles = [[nodenames[i] for i in c] for c in b]

    return namedcycles
end

# return a tuple composed of:
#  * the interconnector name to use when querying the snapshot
#  * a multiplier to apply to the balance of an interconnector
function getintercosign(s::Snapshot, from::String, to::String)
    cname1 = "IC_" * from * "_" * to
    cname2 = "IC_" * to * "_" * from

    if haskey(s.components, cname1)
        cname = cname1
    elseif haskey(s.components, cname2)
        cname = cname2
    else
        throw(AssertionError("Not found: interconnection between " * from * " and " * to))
    end

    (_from, _to) = _fromto_ic_internal(s, s.components[cname])
    if (_from == from) && (_to == to)
        return (cname, 1)
    elseif (_from == to) && (_to == from)
        return (cname, -1)
    else
        throw(AssertionError("Inconsistent interconnection name: " * cname1))
    end
end

# return the interconnection balance in a directed edge
function getbalance(s::Snapshot, from::String, to::String)
    (icname, sign) = getintercosign(s, from, to)
    bin = balance(s, icname, :input, energy, collapse=false, aggregate=false)
    return sign * (bin["input"] - bin["input2"])
end

function getsusceptance(s::Snapshot, from::String, to::String)
    if haskey(s.sim.options[:susceptance], (from,to))
        return s.sim.options[:susceptance][(from,to)]
    elseif haskey(s.sim.options[:susceptance], (to,from))
        return s.sim.options[:susceptance][(to,from)]
    else
        throw(AssertionError("No susceptance found for: " * from * " - " * to))
    end
end

function addkvlconstraints!(s::Snapshot{T}; all::Bool=true) where T
    df = getintercocapacitymatrix(s)
    namedcycles = gencycles(df)

    for c in namedcycles

        hasSE = false        
        exp = Nosy.differentzerovector(T, Nosy.nsteps(s.sim))
        for i in eachindex(c)
            
            # check if cycle includes SE bidding zones
            if c[i] in ("SE1", "SE2", "SE3", "SE4")
                hasSE = true
            end

            if i+1 <= length(c)
                # node i to node i+1
                Bij = getsusceptance(s, c[i], c[i+1])
                add_to_expression!.(exp, getbalance(s, c[i], c[i+1]) / Bij)
            else
                # last node to first node
                Bij = getsusceptance(s, c[i], c[1])
                add_to_expression!.(exp, getbalance(s, c[i], c[1]) / Bij)
            end
        end
        # only apply constraint if cycle includes SE bidding zones
        if all || hasSE
            println("Applying KVL for cycle: " * join(c, " - "))
            @constraint(s.sim.model, exp .== 0.)
        else
            println("Skipping KVL for cycle: " * join(c, " - "))
        end
    end
end