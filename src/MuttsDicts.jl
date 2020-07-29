module MuttsDicts

export MuttsDict
export branch!, double_branch!, mark_immutable!, is_mutable, get_mutable_version

# TODO: make the default constructor mutable, just too weird for newbies
# TODO: explicitly provide overloads for Mutts.branch! etc.?
# TODO: NodeConfig mutable for Serialization.jl sharing? or just ugh.
# TODO: with xor probing, do not need modular, just bound test+subtract.
# TODO: add functional insert/delete?
# TODO: add efficient == operation on dicts (factor out some common code with setdiff.)
# TODO: commented-out asserts should be somehow made optional like @dassert1.
# TODO: hash and equality functions for MuttsDict instances themselves.
# TODO: use split K[]/V[] arrays in Leaf to avoid allocations for isbitstypes?
# TODO: pretty printing
# TODO: unit test for dict[k1, k2, ks...]
# TODO: MuttsDict{Int,Int}(2=>3, 1=>5, ...).
# TODO: size_hint! to preemptively set NodeConfig before populating

include("debug.jl")
include("config.jl")
include("leaf.jl")
include("inode.jl")

# MuttsDict is implemented using a variation on the hashtrie. A MuttsDict object contains
# a root pointer, a population count n, and a NodeConfig that identifies the structure of
# the hashtrie. When a new MuttsDict is created, it initially consists of a MuttsDict
# object pointing to a single Leaf object:
#
# MuttsDict -----> Leaf
#
# The Leaf is a tiny hash table that can accommodate a small number of entries.
# The leaf hash table is keyed by bits 0-15 of the 64-bit key hash.
#
# Once the dictionary reaches size n=16, we change the configuration to incorporate
# a single INode:
#
# MuttsDict ------> INode +-----> Leaf
#                         |-----> Leaf
#                         |-----> Leaf
#                         +-----> Leaf
#
# This INode initially has branch factor 4, with the branch selected by bits 16-17 of the
# key hash.  We use this configuration until we reach n=64, at which point we add another
# INode level with branch factor 4, and the branch selected by bits 24-25 of the key hash:
#
# MuttsDict ------> INode +-----> INode +-----> Leaf
#                         |             |-----> Leaf
#                         |             |-----> Leaf
#                         |             +-----> Leaf
#                         +-----> INode ... (4 Leafs)
#                         |-----> INode ... (4 Leafs)
#                         +-----> INode ... (4 Leafs)
#
# This process continues until there are 6 levels of INodes.  At this point we stop
# adding INode levels, and instead begin increasing the branch factors of the INodes.
# The NodeConfig.inode_capacity[] array contains the branch factors for the INodes:
# initially it is [] (no inodes), then [4,] (a single inode with branch factor 4),
# then [4,4] (two inode levels with branch factor 4), etc. Once we reach [4,4,4,4,4,4],
# we go to [4,4,4,4,4,8], then [4,4,4,4,8,8], etc. Branch factors are always a power of 2.
#
# The increases in bits per INode level are arranged so the branch factor at each INode
# level is Θ(n^(1/7)), with leaf hash tables containing Θ(n^(1/7)) entries on average.
#
# For each Leaf and INode we track whether it is mutable. If a Leaf is mutable, we can
# usually insert a new (k,v) pair by finding a free slot and placing it there. If a Leaf
# is immutable, we copy the Leaf to make a mutable version, then insert the new entry
# in the mutable version. The new leaf pointer is stored in the parent INode, which itself
# may first have to be copied if it is immutable, and so on up to the root.
#
# The 64-bit key hash is partitioned among the INode levels and Leaf like this:
#
# 0000000000000000000000000000000000000000000000000000000000000000
# +-------+-------+-------+-------+-------+-------+--------------+
# inode1  inode2  inode3  inode4  inode5  inode6  leaf
#
# That is, bits 0-15 are for the leaf, bits 16-23 for the last inode level, bits 24-31
# for the second last inode level, etc.
#
# As the NodeConfig changes with increasing n, we use a laziness technique to avoid
# expensive restructuring of the entire hashtrie. To increase the capacity of an INode
# from, say, 4 entries to 8, we mark the subtrees immutable and then have two paths to
# each child:
#
# INode +-----> child0                INode +-----> child0
#       |-----> child1                      |-----> child1
#       |-----> child2    becomes           |-----> child2
#       +-----> child3                      |-----> child3
#                                           |-----> child0
#                                           |-----> child1
#                                           |-----> child2
#                                           +-----> child3
#
# Suppose some key k lives in the subtree child0. Before resizing, the child0 branch
# was taken when the single byte of the hash for this INode matched the pattern
# xxxxxx00. After resizing, there are two paths to child0: xxxxx000 and xxxxx100.
# So whether the next bit of hash(k) is a 0 or 1, we will still reach child0 and
# find key k there. When the next insert occurs to child0, we will do a copy-on-write
# of a leaf, but only retain those keys that match the path used to reach that child.
# We track the path using pathhash/pathmask parameters; an example of a hash path:
#      xxxxxx00xxxxxx11xxxxxx01xxxxxx10xxxxx110xxxxx101xxxxxxxxxxxxxxxx
# which indicates we took child 00 at the first INode, child 11 at the second, etc.
# The hash path is encoded by the pathhash/pathmask parameters:
#      0000000000000011000000010000001000000110000001010000000000000000
#      0000001100000011000000110000001100000111000001110000000000000000
# A 64-bit hash code matches the hash path if (hash & pathmask)==pathhash.
#
# The lazy restructuring means that the hashtrie is really a hash *graph*, with multiple
# paths to reach some leaf nodes. The benefit is that we achieve worst case Θ(n^(1/7)) for
# inserts. This improves on Base.Dict's Θ(n) worst case insert time.

"""
MuttsDict{K,V} provides a dictionary similar to Julia's Dict{K,V}, but with versioning
and improved worst-case asymptotics.  Lookups (getindex) take O(1) time.  Inserts
and updates (`setindex!`) take O(1) amortized time on unversioned dictionaries. You can
create a mutable copy of a dictionary (branch a new version) in O(1) amortized time,
and `setindex!` on a fresh branch is Θ(n^(1/7)).

MuttsDict has been optimized for both space use and cost of immutable inserts. Space use
for small dictionaries is low. For real-time or low-latency applications, MuttsDict
offers a Θ(n^(1/7)) worst case insert/delete time, which is an improvement over
Base.Dict's Θ(n) worst case.

MuttsDict implements the standard dictionary methods `getindex`, `setindex!`, `length`,
`setdiff`, `delete!`, and `iterate`. It is not a subtype of `AbstractDict`, due to
differences between the MuttsDict semantics and those expected by standard library
functions on `AbstractDict`.

MuttsDict implements the "mutable until shared" philosophy for multithreaded programming.
An object local to a single thread can be mutable, and enjoy the more efficient O(1)
amortized insert/delete performance. When objects become shared, they should first be
made immutable (by calling `mark_immutable!` or `branch!`) before sharing. Immutable
MuttsDicts are read-only, and can be safely shared among multiple threads. For lockfree
operation, a thread can branch a shared dictionary, modify it, mark it immutable, then
write the pointer back with an atomic compare-and-swap.

Branching and versioning is handled by the mutts functions `branch!`, `mark_immutable!`,
`is_mutable`, and `get_mutable_version`:
- `dict2=branch!(dict1)` returns a new mutable copy of `dict1`, and marks `dict1`
immutable.
- `mark_immutable!(dict)` marks `dict` as immutable. Once immutable, a MuttsDict can
safely be shared by multiple threads.
- `is_mutable(dict)` returns true when `dict` is mutable.
- `get_mutable_version(dict)` returns `dict` if it is mutable, otherwise returns
`branch!(dict)`.
"""
mutable struct MuttsDict{K,V} #<: AbstractDict{K,V}
    # The root is usually an inode, but for tiny dictionaries it may just be a leaf.
    root::Union{INode{K,V},Leaf{K,V}}

    # Exact population count
    n::Int

    # The height of the tree, and branch factor for each inode.  The NodeConfig is
    # adjusted as n increases.
    config::NodeConfig

    # Note: if you have many dictionaries of the same type which are by default empty,
    # it uses less space to use a single empty, immutable instance as the default, e.g.
    # empty_dict = mark_immutable!(MuttsDict{Int,Int}())
    # dicts = [empty_dict for i=1:10]
    function MuttsDict{K,V}() where {K,V}
        return MuttsDict{K,V}(Leaf{K,V}(1), 0, _config_for_size(1))
    end

    function MuttsDict{K,V}(root,n,config) where {K,V}
        new(root, n, config)
    end
end

"""
    branch!(dict)

Mark dict as immutable, and return a new mutable copy. This operation takes O(1)
time. Changes made to the returned mutable dictionary do not affect `dict`.
"""
function branch!(dict::MuttsDict{K,V}) where {K,V}
    root = dict.root
    mark_immutable!(root)

    # Note: throughout the MuttsDict implementation we use the following
    # pattern for Union{INode,Leaf} types:
    #    if isa(x,Leaf)
    #       ... # leaf stuff I guess
    #    else
    #       ... # inode stuff
    #    end
    # This forces an efficient specialization of the first branch with the compiler
    # knowing x::Leaf, and the second branch with the compiler knowing x::INode.
    # In some cases it is the exact same code in each branch, but it compiles to more
    # efficient code with the above pattern. Julia can often do a similar style of
    # specialization left to its own devices, but it is not guaranteed to happen,
    # and in my experience it is prone to stop happening at deeply inlined loops
    # where performance is critical.
    if isa(root, Leaf{K,V})
        pathmask = UInt64(0)
        pathhash = UInt64(0)
        new_root = _get_mutable_version(root, pathmask, pathhash)
        return MuttsDict{K,V}(new_root, dict.n, dict.config)
    else
        height = length(dict.config.inode_capacity)
        new_root = _get_mutable_version(root, dict.config, height)
        return MuttsDict{K,V}(new_root, dict.n, dict.config)
    end
end

"""
    double_branch!(dict)

Returns two mutable branches of dict. This is useful when you want to create
a mutable branch but keep the original dict mutable:
```
(dict,dict_branch) = double_branch!(dict)
```
"""
function double_branch!(dict::MuttsDict{K,V}) where {K,V}
    return (branch!(dict), branch!(dict))
end

"""
    mark_immutable!(dict)

Marks dict as immutable.
"""
function mark_immutable!(dict::MuttsDict{K,V}) where {K,V}
    root = dict.root
    if isa(root, Leaf{K,V})
        mark_immutable!(root)
    else
        mark_immutable!(root)
    end
end

"""
    is_mutable(dict)

Returns true just when dict is mutable.
"""
function is_mutable(dict::MuttsDict{K,V}) where {K,V}
    root = dict.root
    if isa(root, Leaf{K,V})
        # Branch specialized for isa(root,Leaf{K,V})
        return is_mutable(root)
    else
        # Branch specialized for isa(root,INode{K,V})
        return is_mutable(root)
    end
end

"""
    get_mutable_version(dict)

Returns dict if `is_mutable(dict)`, otherwise returns `branch!(dict)`.
"""
function get_mutable_version(dict::MuttsDict{K,V}) where {K,V}
    if is_mutable(dict)
        return dict
    else
        return branch!(dict)
    end
end

function Base.length(dict::MuttsDict{K,V}) where {K,V}
    return dict.n
end

function Base.copy(dict::MuttsDict{K,V}) where {K,V}
    # Base.copy is incompatible with MuttsDict, because it can result in two competing
    # MuttsDict objects sharing the same underlying tree, with the result that the
    # population count can become inconsistent.
    error("Do not use Base.copy() with MuttsDict{K,V}. Instead use branch!(dict).")
end

function Base.show(io::IO, m::MuttsDict{K,V}) where {K,V}
    print(io, "MuttsDict(")
    entries = [(k,v) for (k,v) in m]
    sep=""
    for (k,v) in entries
        print(io, sep * "$(k)=>$(v)")
        sep=","
    end
    print(io, ")")
end

include("get.jl")
include("insert.jl")
include("delete.jl")
include("setdiff.jl")
include("iterate.jl")
include("merge.jl")
include("tools.jl")

end
