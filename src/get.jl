"""
    getindex(dict, k)

Returns the value `dict[k]`, or throws a `KeyError` if key `k` is not present.
"""
function Base.getindex(dict::MuttsDict{K,V}, k::K) where {K,V}
    hashcode = hash(k)
    node = dict.root

    # INodes
    height = length(dict.config.inode_capacity)
    while isa(node, INode{K,V})
        entries = node.entries
        mask = reinterpret(UInt64, length(entries)-1)
        shift = reinterpret(UInt64, height+1)*UInt64(8)
        slot = 1 + reinterpret(Int64, ((hashcode >> shift) & mask))
        node = @inbounds entries[slot]
        height = height-1
    end

    # Leaf node
    # Note: from the exit condition of the above while loop, the compiler
    # knows ¬isa(node,INode{K,V}) and infers node::Leaf{K,V}.
    num_slots = length(node.entries)
    max_probe2 = min(max_probe-1, num_slots-1)
    for i=0:max_probe2
        index = _hashindex(hashcode, i, num_slots)
        if _slot_occupied(node, index, num_slots)
            (ki,vi) = @inbounds node.entries[index]
            if (k === ki) || isequal(k, ki)
                return vi
            end
        else
            break
        end
    end
    throw(KeyError(k))
end

# d[k1, k2, ks...] is syntactic sugar for d[(k1, k2, ks...)].
getindex(d::MuttsDict, k1, k2, ks...) = getindex(d, tuple(k1, k2, ks...))

function Base.in(_, dict::MuttsDict{K,V}) where {K,V}
    error("""MuttsDict collections only contain Pairs; either look for e.g. A=>B
             instead, or use haskey(k,dict).""")
end

"""
    in((k=>v),dict)

Returns true just when dict contains the key-value pair (k,v).
"""
function Base.in(kv::Pair{K,V}, dict::MuttsDict{K,V}) where {K,V}
    (k,v) = kv
    return Base.in((k,v),dict)
end

"""
    in(k,dict::MuttsDict{K,Nothing})

Useful when using MuttsDict to represent a Set{K}.
"""
function Base.in(k::K, dict::MuttsDict{K,Nothing}) where {K}
    return in((k,nothing), dict)
end

"""
    in((k,v),dict)

Returns true just when dict contains the key-value pair (k,v).
"""
function Base.in((k,v)::Tuple{K,V}, dict::MuttsDict{K,V}) where {K,V}
    hashcode = hash(k)
    node = dict.root

    # Note: there is obvious massive overlap between the implementation of
    # getindex() and in(). This should be ultra-low churn code so I am fine
    # with that.

    # INodes
    height = length(dict.config.inode_capacity)
    while isa(node, INode{K,V})
        entries = node.entries
        mask = reinterpret(UInt64, length(entries)-1)
        shift = reinterpret(UInt64, height+1)*UInt64(8)
        slot = 1 + reinterpret(Int64, ((hashcode >> shift) & mask))
        node = @inbounds entries[slot]
        height = height-1
    end

    # Leaf node
    num_slots = length(node.entries)
    max_probe2 = min(max_probe-1, num_slots-1)
    for i=0:max_probe2
        index = _hashindex(hashcode, i, num_slots)
        if _slot_occupied(node, index, num_slots)
            (ki,vi) = @inbounds node.entries[index]
            if (k === ki) || isequal(k,ki)
                return (v === vi) || isequal(v, vi)
            end
        else
            break
        end
    end
    return false
end

"""
    get(dict, k, default)

Returns the value `dict[k]`, or `default` if key `k` is not present.
"""
function Base.get(dict::MuttsDict{K,V}, k::K, default) where {K,V}
    hashcode = hash(k)
    node = dict.root

    # INodes
    height = length(dict.config.inode_capacity)
    while isa(node, INode{K,V})
        entries = node.entries
        mask = reinterpret(UInt64, length(entries)-1)
        shift = reinterpret(UInt64, height+1)*UInt64(8)
        slot = 1 + reinterpret(Int64, ((hashcode >> shift) & mask))
        node = @inbounds entries[slot]
        height = height-1
    end

    # Leaf node
    # Note: from the exit condition of the above while loop, the compiler
    # knows ¬isa(node,INode{K,V}) and infers node::Leaf{K,V}.
    num_slots = length(node.entries)
    max_probe2 = min(max_probe-1, num_slots-1)
    for i=0:max_probe2
        index = _hashindex(hashcode, i, num_slots)
        if _slot_occupied(node, index, num_slots)
            (ki,vi) = @inbounds node.entries[index]
            if (k === ki) || isequal(k,ki)
                return vi
            end
        else
            break
        end
    end
    return default
end

"""
    haskey(dict,k)

Returns true just when dict contains the key k.
"""
function Base.haskey(dict::MuttsDict{K,V}, k::K) where {K,V}
    return get(dict, k, Base.secret_table_token) != Base.secret_table_token
end
