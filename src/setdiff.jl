"""
    setdiff(d1,d2)

Find set difference between two MuttsDict{K,V}.  Returns an unordered Vector{K,V}
enumerating the (key,value) pairs that are in d1 but not d2.

Internal nodes that are common to both d1 and d2 are skipped.  If d2 is obtained
by branching d1 and performing δ insert/delete operations, the cost of setdiff
is ϴ(δ n^(1/7)).  (This also applies if d1 derives from a branch of d2.)
"""
function Base.setdiff(d1::MuttsDict{K,V}, d2::MuttsDict{K,V}) where {K,V}
    # Recursively traverse d2. At each node of d2, check whether the current hash path
    # reaches the same node in d1; if so, skip the subtree. When get to a leaf that is
    # in d1 but not d2, iterate the entries and compare to d2.
    diffs = Vector{Tuple{K,V}}()
    height = length(d1.config.inode_capacity)
    pathmask = UInt64(0)
    pathhash = UInt64(0)
    _collect_diffs(diffs, d1.root, d2, height, pathmask, pathhash)
    return diffs
end

# Collect diffs for an inode subtree in d1
function _collect_diffs(diffs::Vector{Tuple{K,V}},
    inode::INode{K,V},
    d2::MuttsDict{K,V},
    height::Int,
    pathmask::UInt64,
    pathhash::UInt64
) where {K,V}
    if _has_node(d2, objectid(inode), pathmask, pathhash)
        # This path reaches the same node object in both dictionaries, so there
        # will be no diffs in this subtree.
        return
    end

    if isa(inode.entries, Vector{INode{K,V}})
        capacity = length(inode.entries)
        mask = reinterpret(UInt64, capacity-1)
        shift = reinterpret(UInt64, height+1)*UInt64(8)
        subtree_pathmask = pathmask | (mask << shift)
        for i=1:capacity
            subtree_pathhash = pathhash | ((i-1) << shift)
            child_inode = @inbounds inode.entries[i]
            _collect_diffs(diffs, child_inode, d2, height-1, subtree_pathmask,
                subtree_pathhash)
        end
    else
        # Branch specialized for isa(inode.entries,Vector{Leaf{K,V}})
        capacity = length(inode.entries)
        mask = reinterpret(UInt64, capacity-1)
        shift = reinterpret(UInt64,height+1)*UInt64(8)
        subtree_pathmask = pathmask | (mask << shift)
        for i=1:capacity
            subtree_pathhash = pathhash | ((i-1) << shift)
            leaf = @inbounds inode.entries[i]
            _collect_diffs(diffs, leaf, d2, height-1, subtree_pathmask, subtree_pathhash)
        end
    end
end

# Collect diffs for a leaf in d1
function _collect_diffs(diffs::Vector{Tuple{K,V}},
    leaf::Leaf{K,V},
    d2::MuttsDict{K,V},
    height::Int,
    pathmask::UInt64,
    pathhash::UInt64
) where {K,V}
    if _has_node(d2, objectid(leaf), pathmask, pathhash)
        # This path reaches the same node object in both dictionaries, so there
        # will be no diffs in this subtree.
        return
    end

    # Collect diffs from individual entries in this leaf
    num_slots = length(leaf.entries)
    for i=1:num_slots
        slot = reinterpret(UInt64,i)
        if _slot_occupied(leaf, slot, num_slots)
            (ki,vi) = @inbounds leaf.entries[i]
            h = hash(ki)
            if (h & pathmask) == pathhash
                if !in((ki,vi),d2)
                    push!(diffs, (ki,vi))
                end
            end
        end
    end
end

# Returns true if dict contains a node where objectid(node)==id, reachable along
# the specified path.
function _has_node(dict::MuttsDict{K,V}, id::UInt64, pathmask, pathhash) where {K,V}
    node = dict.root
    (objectid(node) == id) && return true
    height = length(dict.config.inode_capacity)
    while isa(node, INode{K,V})
        entries = node.entries
        mask = reinterpret(UInt64, length(entries)-1)
        shift = reinterpret(UInt64, height+1)*UInt64(8)
        slot = 1 + reinterpret(Int64, ((pathhash >> shift) & mask))
        node = @inbounds entries[slot]
        if objectid(node) == id
            return true
        end
        height -= 1
    end

    return false
end

function Base.:(==)(dict1::MuttsDict{K,V}, dict2::MuttsDict{K,V}) where {K,V}
    (dict1 === dict2) && return true
    (length(dict1) != length(dict2)) && return false
    if length(dict1) < 20
        # Small dictionary - iterate & lookup, avoid overhead of allocation from
        # setdiff()
        for (k,v) in dict1
            !((k,v) in dict2) && return false
        end
        return true
    else
        return isempty(setdiff(dict1,dict2))
    end
end
