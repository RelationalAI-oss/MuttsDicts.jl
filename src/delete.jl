
"""
    delete!(dict, k)

Deletes the entry for `k`, if it exists. Returns -1 if `k` was found, 0
if not found.
"""
function Base.delete!(dict::MuttsDict{K,V}, k::K) where {K,V}
    @dassert1 is_mutable(dict)
    _delete!(dict, hash(k), k)
    return dict
end

function _delete!(dict::MuttsDict{K,V}, hashcode::UInt64, k::K) where {K,V}
    root = dict.root
    pathmask = UInt64(0)
    pathhash = UInt64(0)
    if isa(root, Leaf{K,V})
        # Branch specialized for isa(root,Leaf{K,V})
        (!is_mutable(root)) && error("delete!($(typeof(dict)), ..): dict is immutable")
        (new_root,size_change) = _delete!(root, hashcode, k, pathmask, pathhash)
        dict.root = new_root
    else
        # Branch specialized for isa(root,INode{K,V})
        (!is_mutable(root)) && error("delete!($(typeof(dict)), ..): dict is immutable")
        config = dict.config
        height = length(config.inode_capacity)
        size_change = _delete!(root, config, height, hashcode, k,
            pathmask, pathhash)
    end
    dict.n += size_change
    return size_change
end

# delete!() is not designed to be a frequent operation, this method is
# going to always clone the leaf node. This is so that get() and insert!()
# can stop probing when they encounter an empty slot.
function _delete!(leaf::Leaf{K,V},
    hashcode::UInt64,
    k::K,
    pathmask::UInt64,
    pathhash::UInt64
) where {K,V}
    num_slots = length(leaf.entries)
    new_leaf = Leaf{K,V}(num_slots)

    found = false
    for i=1:num_slots
        slot = reinterpret(UInt64, i)
        if _slot_occupied(leaf, slot, num_slots)
            (ki,vi) = @inbounds leaf.entries[i]
            if (ki === k) || isequal(ki,k)
                found = true
                continue
            end
            h = hash(ki)
            if (h & pathmask) == pathhash
                (new_leaf,_) = _insert!(new_leaf, h, ki, vi)
            end
        end
    end

    if found
        return (new_leaf,-1)
    else
        return (leaf,0)
    end
end

function _delete!(inode::INode{K,V},
    config::NodeConfig,
    height::Int,
    hashcode::UInt64,
    k::K,
    pathmask=UInt64(0),
    pathhash=UInt64(0)
) where {K,V}
    @dassert1 inode.is_mutable
    mask = reinterpret(UInt64, length(inode.entries)-1)
    shift = reinterpret(UInt64, height+1)*UInt64(8)
    slot = 1 + ((hashcode >> shift) & mask)
    pathmask = pathmask | (mask << shift)
    pathhash = pathhash | ((slot-1) << shift)
    entries = inode.entries
    if isa(entries, Vector{Leaf{K,V}})
        @dassert1 height==1
        leaf = @inbounds entries[slot]
        (new_leaf,size_change) = _delete!(leaf, hashcode, k, pathmask, pathhash)
        if new_leaf != leaf
            entries[slot] = new_leaf
        end
        return size_change
    else
        child_inode = @inbounds entries[slot]
        child_inode = _get_mutable_version(child_inode, config, height-1)
        size_change = _delete!(child_inode, config, height-1, hashcode, k, pathmask, pathhash)
        @inbounds inode.entries[slot] = child_inode
        return size_change
    end
end
