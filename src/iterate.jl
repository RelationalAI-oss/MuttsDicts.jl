mutable struct Iterator{K,V}
    # We used to have path::Vector{Tuple{INode{K,V},Int}} here, but to reduce allocations in
    # older versions of julia it was changed to two vectors, one of inodes, and one of indexes
    # in the inodes. In the future we can revert this change. 
    path_inode::Vector{INode{K,V}}
    path_i::Vector{Int}
    leaf::Leaf{K,V}
    leaf_index::Int
    pathmask::UInt64
    pathhash::UInt64
end

function Base.iterate(dict::MuttsDict{K,V}) where {K,V}
    if dict.n == 0
        return nothing
    end

    iter = _make_iterator(dict)
    return _iterate_next(iter)
end

function Base.iterate(::MuttsDict{K,V}, iter::Iterator{K,V}) where {K,V}
    return _iterate_next(iter)
end

# Avoid allocating when iterating tiny dictionaries that contain just a single leaf.
@generated function _empty_vector(::Type{T}) where {T}
    vec = T[]
    return vec
end

# Returns an Iterator{K,V} positioned before the first record. Must call _next(iter)
# before attempting to get the key/value pair.
function _make_iterator(dict::MuttsDict{K,V}) where {K,V}
    root = dict.root
    pathmask = UInt64(0)
    pathhash = UInt64(0)
    if isa(root, Leaf{K,V})
        leaf = root::Leaf{K,V}
        # Note: it is safe to pass the shared `_empty_path(K,V)` instance here, because
        # we know it will not be mutated in _next(), since root isa Leaf.
        path_inode = _empty_vector(INode{K,V})
        path_i = _empty_vector(Int)
        return Iterator{K,V}(path_inode, path_i, leaf, 0, pathmask, pathhash)
    end

    # Descend to leftmost leaf
    path_inode = INode{K,V}[]
    path_i = Int[]
    node = root::INode{K,V}
    while isa(node, INode{K,V})
        push!(path_inode, node)
        push!(path_i, 1)
        pathmask = (pathmask << UInt64(8)) | (length(node.entries)-1)
        pathhash = (pathhash << UInt64(8))
        if isa(node.entries, Vector{Leaf{K,V}})
            # Specialize this path to avoid dynamic typing
            node = @inbounds node.entries[1]
            break
        end
        node = @inbounds node.entries[1]
    end
    pathmask = pathmask << UInt64(16)
    pathhash = pathhash << UInt64(16)
    return Iterator{K,V}(path_inode, path_i, node::Leaf{K,V}, 0, pathmask, pathhash)
end

function _iterate_next(iter::Iterator{K,V}) where {K,V}
    if _next(iter)
        i = iter.leaf_index
        (ki,vi) = @inbounds iter.leaf.entries[i]
        return ((ki,vi),iter)
    else
        return nothing
    end
end

function _next(iter::Iterator{K,V}) where {K,V}
    height = length(iter.path_inode)
    while true
        # Scan for the next (k,v) pair in the leaf
        num_slots = length(iter.leaf.entries)
        leaf = iter.leaf
        for i in iter.leaf_index+1:num_slots
            if _slot_occupied(leaf, reinterpret(UInt64,i), num_slots)
                (ki,vi) = @inbounds leaf.entries[i]
                h = hash(ki)
                if (h & iter.pathmask) == iter.pathhash
                    iter.leaf_index = i
                    return true
                end
            end
        end

        # Lowest 16 bits are for leaf
        iter.pathmask >>= UInt64(16)
        iter.pathhash >>= UInt64(16)

        # Ascend until we are in a child with a right sibling
        while length(iter.path_inode) > 0
            node = pop!(iter.path_inode)
            i = pop!(iter.path_i)
            iter.pathmask >>= UInt64(8)
            iter.pathhash >>= UInt64(8)
            if node.entries isa Vector{INode{K,V}}
                # This branch is specialized for Vector{INode{K,V}}
                if i < length(node.entries)
                    push!(iter.path_inode, node)
                    push!(iter.path_i, i+1)
                    iter.pathmask = (iter.pathmask << UInt64(8)) | (length(node.entries)-1)
                    iter.pathhash = (iter.pathhash << UInt64(8)) | i
                    break
                end
            else
                # This branch is specialized for Vector{Leaf{K,V}}
                if i < length(node.entries)
                    push!(iter.path_inode, node)
                    push!(iter.path_i, i+1)
                    iter.pathmask = (iter.pathmask << UInt64(8)) | (length(node.entries)-1)
                    iter.pathhash = (iter.pathhash << UInt64(8)) | i
                    break
                end
            end
        end

        # Have reached root? If so, done.
        if length(iter.path_inode) == 0
            iter.leaf_index = 0
            return false
        end

        # Descend through leftmost children
        node = iter.path_inode[end]
        i = iter.path_i[end]
        while true
            if node.entries isa Vector{Leaf{K,V}}
                (node,i) = (node.entries[i],1)
                break
            end
            (node,i) = (node.entries[i],1)
            push!(iter.path_inode, node)
            push!(iter.path_i, i)

            if node.entries isa Vector{Leaf{K,V}}
                # This branch is specialized for Vector{Leaf{K,V}}
                entries_mask = reinterpret(UInt64,length(node.entries)-1)
                iter.pathmask = (iter.pathmask << UInt64(8)) | entries_mask
                iter.pathhash = (iter.pathhash << UInt64(8))
            else
                # This branch is specialized for Vector{INode{K,V}}
                entries_mask = reinterpret(UInt64,length(node.entries)-1)
                iter.pathmask = (iter.pathmask << UInt64(8)) | entries_mask
                iter.pathhash = (iter.pathhash << UInt64(8))
            end
        end

        iter.pathmask <<= UInt64(16)
        iter.pathhash <<= UInt64(16)
        iter.leaf = node::Leaf{K,V}
        iter.leaf_index = 0
    end
end

function _get_key(iter::Iterator{K,V})::K where {K,V}
    @assert iter.leaf_index != 0
    (k,_) = @inbounds iter.leaf.entries[iter.leaf_index]
    return k
end

function _get_value(iter::Iterator{K,V})::V where {K,V}
    @assert iter.leaf_index != 0
    (_,v) = @inbounds iter.leaf.entries[iter.leaf_index]
    return v
end

# More efficient version that avoids allocations from the
# return value of Base.iterate().
function Base.foreach(f, dict::MuttsDict{K,V}) where {K,V}
    iter = _make_iterator(dict)
    while _next(iter)
        k = _get_key(iter)
        v = _get_value(iter)
        f(k, v)
    end
end

"""
    keys(dict)

Returns an iterator over the keys in the dict.
"""
function Base.keys(dict::MuttsDict)
    return (k for (k, _) in dict)
end
