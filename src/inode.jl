
# Internal node (INode). For a large dictionary, the MuttsDict consists of a
# tree of depth 7, where the first 6 nodes along any path are INodes.
# INodes are trie nodes with a branching factor 2^k for some k.  The branching
# factor k increases with N, according to the NodeConfig — see _config_for_size(N).
#
# The 64-bit hash value of a key is partitioned among the nodes as follows:
# 0000000000000000000000000000000000000000000000000000000000000000
# +-------+-------+-------+-------+-------+-------+--------------+
# inode1  inode2  inode3  inode4  inode5  inode6  leaf
#
# For example, to navigate from inode1 to the appropriate second-level inode
# for a key, we would choose child (hashcode >> 56) & mask,
# where mask=length(INode.entries)-1.
mutable struct INode{K,V}
    entries::Union{Vector{INode{K,V}},Vector{Leaf{K,V}}}
    is_mutable::Bool

    function INode{K,V}(capacity::Int, child) where {K,V}
        @dassert1 ispow2(capacity)
        entries = Vector{typeof(child)}(undef, capacity)
        for i=1:capacity
            @inbounds entries[i] = child
        end
        new(entries, true)
    end

    # Enlarge the capacity of an INode.  For example, when going from
    # children[1..4] to capacity 8, the resulting INode would have entries
    # [children[1], ..., children[4], children[1], ..., children[4]]
    function INode{K,V}(capacity::Int, children::Vector{T}) where {K,V,T}
        @dassert1 ispow2(capacity)
        @dassert1 ispow2(length(children))
        @dassert1 capacity > length(children)
        entries = typeof(children)(undef, capacity)
        pos = 1
        for i=1:capacity
            @dassert1 !is_mutable(children[pos])
            entries[i] = children[pos]
            pos += 1
            if pos == length(children)+1
                pos = 1
            end
        end
        new(entries,true)
    end

    function INode{K,V}(entries::Vector{T}, is_mutable::Bool) where {K,V,T}
        new(entries, is_mutable)
    end
end

is_mutable(inode::INode{K,V}) where {K,V} = inode.is_mutable

function _get_mutable_version(inode::INode{K,V}, config::NodeConfig, height::Int) where {K,V}
    depth = 1 + length(config.inode_capacity) - height
    should_have_capacity = config.inode_capacity[depth]   # TODO: @inbounds
    if length(inode.entries) != should_have_capacity
        # Need to enlarge the branching factor of this inode. Mark all descendents as
        # immutable, since they will now be reachable by multiple paths
        mark_immutable!(inode)

        # Construct a new inode with increased capacity.  When an inode with
        # entries=[x0,x1,x2,x3] gets increased in size by one bit, the new
        # entries is [x0,x1,x2,x3,x0,x1,x2,x3].
        return INode{K,V}(should_have_capacity, inode.entries)
    elseif inode.is_mutable
        return inode
    else
        new_inode = INode{K,V}(copy(inode.entries), true)
        return new_inode
    end
end

function mark_immutable!(inode::INode{K,V}) where {K,V}
    (!inode.is_mutable) && return
    entries = inode.entries
    if isa(entries, Vector{Leaf{K,V}})
        # Branch specialized for Vector{Leaf{K,V}}
        for child in entries
            mark_immutable!(child)
        end
    else
        # Branch specialized for Vector{INode{K,V}}
        for child in entries
            mark_immutable!(child)
        end
    end
    inode.is_mutable = false
end
