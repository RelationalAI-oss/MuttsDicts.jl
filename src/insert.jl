function Base.setindex!(dict::MuttsDict{K,V}, v::V, k::K) where {K,V}
    insert!(dict, k, v)
    return v
end

# d[k1, k2, ks...] is syntactic sugar for d[(k1, k2, ks...)].
setindex!(d::MuttsDict, v, k1, k2, ks...) = setindex!(d, v, tuple(k1, k2, ks...))

"""
    insert!(dict, k, v)

Inserts the `(k,v)` pair in the dictionary, replacing any previous entry for `k`.
Returns +1 if a new entry was inserted, or 0 if a previous entry was replaced.
"""
function Base.insert!(dict::MuttsDict{K,V}, k::K, v::V) where {K,V}
    @dassert1 is_mutable(dict)
    _insert!(dict, hash(k), k, v)
end

function _insert!(dict::MuttsDict{K,V}, hashcode::UInt64, k::K, v::V) where {K,V}
    root = dict.root
    if isa(root, Leaf{K,V})
        # Branch specialized for isa(root,Leaf{K,V})
        (!is_mutable(root)) && error("insert!($(typeof(dict)), ..): dict is immutable")
        (new_root,size_change) = _insert!(root, hashcode, k, v)
        dict.root = new_root
    else
        # Branch specialized for isa(root,INode{K,V})
        (!is_mutable(root)) && error("insert!($(typeof(dict)), ..): dict is immutable")
        config = dict.config
        height = length(config.inode_capacity)
        pathmask = UInt64(0)
        pathhash = UInt64(0)
        size_change = _insert!(root, config, height, hashcode, k, v,
            pathmask, pathhash)
    end
    @dassert1(size_change <= 1)
    dict.n += size_change

    # Check if we need to change configurations
    if dict.n == dict.config.next_config_size
        new_config = _config_for_size(dict.n)
        @dassert1 new_config.next_config_size > dict.n
        if length(new_config.inode_capacity) > length(dict.config.inode_capacity)
            # Increase depth
            @dassert1 length(new_config.inode_capacity) == 1+length(dict.config.inode_capacity)
            mark_immutable!(dict.root)
            dict.root = INode{K,V}(new_config.inode_capacity[1], dict.root)
        elseif isa(dict.root, INode{K,V})
            # Possible resizing of root inode
            height = length(config.inode_capacity)
            dict.root = _get_mutable_version(dict.root, new_config, height)
        end
        dict.config = new_config
    end
    return size_change
end

function _insert!(inode::INode{K,V},
    config::NodeConfig,
    height::Int,
    hashcode::UInt64,
    k::K,
    v::V,
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
        leaf = _get_mutable_version(leaf, pathmask, pathhash)
        (leaf,size_change) = _insert!(leaf, hashcode, k, v)
        @inbounds entries[slot] = leaf
        return size_change
    else
        child_inode = @inbounds entries[slot]
        child_inode = _get_mutable_version(child_inode, config, height-1)
        size_change = _insert!(child_inode, config, height-1, hashcode, k, v, pathmask, pathhash)
        @inbounds inode.entries[slot] = child_inode
        return size_change
    end
end

# Returns (new_leaf,size_change)
# Note: In Julia 1.4 returning a `(mutable_object,Int)` tuple still allocates,
# so we're allocating on every insert. This is fixed in newer Julia versions.
function _insert!(leaf::Leaf{K,V}, hashcode::UInt64, k::K, v::V) where {K,V}
    @dassert1 is_mutable(leaf)
    num_slots = length(leaf.entries)
    max_probe2 = min(max_probe-1, num_slots-1)
    for i=0:max_probe2
        index = _hashindex(hashcode, i, num_slots)
        if _slot_occupied(leaf, index, num_slots)
            # If the key is here replace the entry, otherwise keep probing
            (ki,vi) = @inbounds leaf.entries[index]
            if (k === ki) || isequal(k, ki)
                _put_entry(leaf, index, k, v)
                return (leaf,0)
            end
        else
            # Found an empty slot - place the entry here
            _put_entry(leaf, index, k, v)
            return (leaf,1)
        end
    end

    # Reached maximum probe length, resize.  Rather then modifying this leaf in place,
    # we create a new leaf with greater capacity and copy the entries there. This is
    # simpler, and handles the case where because of rotten luck we exceed max_probe
    # inserting to the new leaf, and have to enlarge the leaf a second time (or more).
    new_capacity = _next_leaf_table_size(num_slots)
    new_leaf = Leaf{K,V}(new_capacity)

    for i=1:length(leaf.entries)
        slot = reinterpret(UInt64,i)
        if _slot_occupied(leaf, slot, num_slots)
            (ki,vi) = @inbounds leaf.entries[i]
            h = hash(ki)
            (new_leaf,_) = _insert!(new_leaf, h, ki, vi)
        end
    end
    return _insert!(new_leaf, hashcode, k, v)
end
