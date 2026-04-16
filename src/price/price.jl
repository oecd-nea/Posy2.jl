"""
Build component in an alternative manner:
  * replace integer constraint with fix @ opti
  * replace variable capacity with fixed capacity @ opti
1 denotes run 1 (with variable capacity and integers)
2 denotes run 2 (with fixed capacity and fixed integers)
"""

using JuMP
using Nosy: build, buildbehavior, shallowcopy, portstructure, _sortbehaviordata, _addbehavior!
using Nosy: _apply_constraints!
using Nosy: AbstractModelData, AbstractBehaviorData, AbstractJointFlowData, AbstractCarrier
using Nosy: AbstractComponent, AbstractRegularBehavior, AbstractJointFlow
using Nosy: FleetUnitCommitmentBehavior

function duplicatecarrierforprice(c1::AbstractCarrier, sim2::Sim)
    return typeof(c1)(c1.name, sim2, energy=c1.energy)
end

function duplicatecarrierforprice(c1::CO2Carrier, sim2::Sim)
    return typeof(c1)(c1.name, sim2, weight=c1.weight[1])
end

# get all carriers from nodes
# duplicate them
# return a dict to match s1 and s2 carriers
function duplicatecarriers(s::Snapshot, opt)
    jumpmodel = Model(opt)
    sim = Sim(s.sim.mesh, jumpmodel, s.sim.options)
    d = Dict()
    for (nodename,node) in s.nodes
        if !haskey(d, node.carrier)
            d[node.carrier] = duplicatecarrierforprice(node.carrier, sim)
        end
    end
    return d
end

function buildmodeldataforprice(m::AbstractModelData, dcarriers)
    vp = []
    for n in propertynames(m)
        p = getproperty(m, n)
        # all properties are propagated except sim and carriers
        if p isa AbstractCarrier
            push!(vp, dcarriers[p])
        elseif p isa Sim
            push!(vp, sim(first(dcarriers)[2]))
        else
            push!(vp, p)
        end
    end
    return typeof(m)(vp...)
end

buildbehaviorforprice(c2::AbstractComponent, b::AbstractBehaviorData, c1::AbstractComponent, dcarriers) = buildbehavior(c2, b)


function buildbehaviorforprice(c2::AbstractComponent, b::VariableCapacity, c1::AbstractComponent, dcarriers)
    f = FixedCapacity(
        b.pname, 
        b.modifier, 
        capacity(c1, b.pname), # capacity taken from optimized c1
        unitsize = b.unitsize
    )
    return buildbehavior(c2, f)
end

function buildbehaviorforprice(c2::AbstractComponent, b::AbstractJointFlowData, c1::AbstractComponent, dcarriers)
    vp = []
    for n in propertynames(b)
        p = getproperty(b, n)
        # all properties are propagated except sim and carriers
        if p isa AbstractCarrier
            push!(vp, dcarriers[p])
        elseif p isa Sim
            push!(vp, sim(first(dcarriers)[2]))
        else
            push!(vp, p)
        end
    end
    return buildbehavior(c2, typeof(b)(vp...))
end

function fix_v!(vexp, vfix)
    for (e,f) in zip(vexp, vfix)
        if Nosy._is_equivalent_to_variable(e)
            set_upper_bound(e, f)
            set_lower_bound(e, f)
        end
    end
end

function buildbehaviorforprice(c2::AbstractComponent, b::UnitCommitment, c1::AbstractComponent, dcarriers)
    vp = []
    for n in propertynames(b)
        p = getproperty(b, n)
        # all properties are propagated except sim and carriers
        if p isa AbstractCarrier
            push!(vp, dcarriers[p])
        elseif p isa Sim
            push!(vp, sim(first(dcarriers)[2]))
        elseif n == :integer
            push!(vp, false) # no integer commitment
        else
            push!(vp, p)
        end
    end

    uc = buildbehavior(c2, typeof(b)(vp...))

    # fix integer variables of UC to optimality
    uc1 = first(filter(x->x.data == b, Nosy.getbehaviors(c1, FleetUnitCommitmentBehavior)))


    fix_v!(uc.startup, JuMP.value.(uc1.startup))
    fix_v!(uc.shutdown, JuMP.value.(uc1.shutdown))
    fix_v!(uc.state, JuMP.value.(uc1.state))

    return uc
end

function rebuildcomponentforprice(c1::Component, dcarriers)
    mdata = buildmodeldataforprice(c1.model.data, dcarriers)

    m = build(mdata, c1.name)

    c2 = Component(
        c1.name,
        m,
        Vector{AbstractRegularBehavior{AffExpr}}(undef,0),
        Vector{AbstractJointFlow{AffExpr}}(undef,0),
        c1.tags,
        shallowcopy(portstructure(m))
    )

    behaviors = vcat([b.data for b in c1.behaviors]..., [b.data for b in c1.jointflows])
    vbehaviordata = _sortbehaviordata(behaviors)

    for b in vbehaviordata
        _b = buildbehaviorforprice(c2, b, c1, dcarriers)
        _addbehavior!(c2, _b)
    end

    _apply_constraints!(c2)

    return c2
end

function buildnodeforprice(n1::Node, dcarriers)
    Node(n1.name, dcarriers[n1.carrier], losses=n1.losses, rule=n1.rule, evalprice=n1.evalprice, tags=n1.tags)
end


function rebuildsnapshotforprice(s1::Snapshot)
    # build sim and carriers
    dcarriers = duplicatecarriers(s1, HiGHS.Optimizer)
    _sim = sim(first(dcarriers)[2])
    
    # build snapshots
    s2 = Snapshot(_sim)

    # build nodes
    dnodes = Dict()
    for (nodename,node) in s1.nodes
        dnodes[nodename] = buildnodeforprice(node, dcarriers)
    end

    # build components
    dcomp = Dict()
    for (cname, comp) in s1.components
        dcomp[cname] = rebuildcomponentforprice(comp, dcarriers)
    end

    # TODO connect (iterate on s1 nodes, connect the same for s2)
    for (nodename,node) in s1.nodes
        for (cname, _) in node.s.input
            connect!(s2, dcomp[cname], dnodes[nodename])
        end
        for (cname, _) in node.s.output
            if cname != "losses" && !haskey(dcomp[cname].s.input, nodename) # some ports were already connected via input
                connect!(s2, dcomp[cname], dnodes[nodename])
            end
        end
    end

    return s2
end

function reoptimizeforprice(s::Snapshot, metric=cost)
    s2 = rebuildsnapshotforprice(s)
    Nosy.optimize!(s2, metric(s2))
    return extract(s2)
end