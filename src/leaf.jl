# Leaf node: contains a small hash table of size O(n^(1/7))
mutable struct Leaf{K,V}
    # Bitmap of which slots are occupied, if length(entries) <= 63.  MSB is used for
    # the mutable flag.
    slots::UInt64

    # Used if length(entries) > 63.
    big_slots::BitVector
    entries::Vector{Tuple{K,V}}

    function Leaf{K,V}(capacity::Int) where {K,V}
        entries = Vector{Tuple{K,V}}(undef, capacity)
        # MSB of slots is the 'is_mutable' bit
        slots = 0x8000000000000000
        if capacity <= 63
            big_slots = _empty_big_slots()
        else
            big_slots = BitVector(undef, capacity)
            for i=1:capacity
                @inbounds big_slots[i] = false
            end
        end
        return new(slots, big_slots, entries)
    end

    function Leaf{K,V}(slots, big_slots, entries) where {K,V}
        return new(slots, big_slots, entries)
    end
end

# Maximum number of probes we will perform in a leaf hash table.  max_probe must be a
# constant for asymptotics. The smaller the constant, the more wasted space, because leaf
# enlargement is triggered by exceeding max_probes on an insert. 16 is a reasonable number
# of probes. Because of the xor probing you get reasonable cache locality, so 16 probes
# doesn't translate into 16 cache misses, e.g. for 16-byte (k,v) pairs you're looking at
# maybe 4-5 cacheline misses as the max. But usually 1-2 cachelines for a probe sequence.
const max_probe = 16

# Sequence of hash table sizes for the leaves, where the first few table sizes are
# 1,2,3,4.. to conserve space, and each successive size is usually not more than 5/4 the
# value of the previous. The exponential sequence of sizes (increase factor ~ 5/4)
# gives Θ(1) amortization for inserts, similar to how a typical dynamic Vector doubles in
# size to give amortized Θ(1) insert cost. Using a 5/4 increase ensures that we will
# usually have no more than 20% empty slots.
const _leaf_table_sizes = [1,2,3,4,5,6,8,11,13,15,19,23,27,33,41,47,59,73,89,113,127,147,163,191,233]

# Returns the appropriate table size for storing N items
function _leaf_table_size(N::Int)
    rough_capacity = convert(Int, ceil(N*11/10))
    pos = searchsortedfirst(_leaf_table_sizes, rough_capacity)
    if pos <= length(_leaf_table_sizes)
        return _leaf_table_sizes[pos]
    else
        return convert(Int, ceil(N*5/4))
    end
end

# Returns the next largest table size, given the current capacity
function _next_leaf_table_size(capacity::Int)
    pos = searchsortedfirst(_leaf_table_sizes, capacity)
    if pos < length(_leaf_table_sizes)
        return _leaf_table_sizes[pos+1]
    else
        # This should be unreachable; would need a bad hash function or
        # N > 10^16 for this to be used.
        return convert(Int, ceil(capacity*5/4))
    end
end

@inline function _slot_occupied(leaf::Leaf{K,V}, slot::UInt64, num_slots::Int) where {K,V}
    @dassert1 (slot >= 1) && (slot <= num_slots)
    if num_slots <= 63
        return (leaf.slots & (UInt64(1) << (slot-1))) != UInt64(0)
    else
        slot2 = reinterpret(Int64, slot)
        return @inbounds leaf.big_slots[slot2]
    end
end

function is_mutable(leaf::Leaf{K,V}) where {K,V}
    return (leaf.slots & 0x8000000000000000) != 0
end

function mark_immutable!(leaf::Leaf{K,V}) where {K,V}
    leaf.slots = leaf.slots & 0x7fffffffffffffff
    @dassert1 !is_mutable(leaf)
end

function _get_mutable_version(
    leaf::Leaf{K,V},
    pathmask::UInt64,
    pathhash::UInt64
) where {K,V}
    is_mutable(leaf) && return leaf
    num_slots = length(leaf.entries)

    # Filter out entries which do not belong to this path
    count=0
    for i=1:num_slots
        slot = reinterpret(UInt64, i)
        if _slot_occupied(leaf, slot, num_slots)
            (ki,vi) = @inbounds leaf.entries[i]
            h = hash(ki)
            if (h & pathmask) == pathhash
                count += 1
            end
        end
    end

    new_capacity = _leaf_table_size(count)
    new_leaf = Leaf{K,V}(new_capacity)
    for i=1:num_slots
        slot = reinterpret(UInt64, i)
        if _slot_occupied(leaf, slot, num_slots)
            (ki,vi) = @inbounds leaf.entries[i]
            h = hash(ki)
            if (h & pathmask) == pathhash
                (new_leaf, _) = _insert!(new_leaf, h, ki, vi)
            end
        end
    end
    return new_leaf
end

function _put_entry(leaf::Leaf{K,V}, index::UInt64, k::K, v::V) where {K,V}
    @dassert1 (index >= 1) && (index <= length(leaf.entries))
    @inbounds leaf.entries[index] = (k,v)
    num_slots = length(leaf.entries)
    if num_slots <= 63
        leaf.slots |= UInt64(1) << UInt64(index-1)
    else
        @inbounds leaf.big_slots[index] = true
    end
end

# Returns the ith slot in the hash table probe sequence: i=0 is the first
# slot we check, i=1 the second etc.  We use an xor probe sequence,
# where the slot is xor(hashcode,i) modulo number of slots.  This probe
# sequence is fast to compute and gives good cache-locality, because you
# check all the slots in a cacheline before moving to a new cacheline.
# TODO: consider a probing sequence that mixes the cache-locality of xor
# with an anti-clumping measure, e.g., bottom two bits from xor, top bits
# from quadratic probe sequence.
@inline function _hashindex(hashcode::UInt64, i::Int, num_slots::Int)
    ui = reinterpret(UInt64, i)
    z = xor(hashcode, ui)

    # TODO: z = 1+((z >= num_slots) ? z-num_slots : z)
    return 1+Base.checked_urem_int(z, reinterpret(UInt64, num_slots))
end

# Unique instance of an empty BitVector
@generated function _empty_big_slots()
    return BitVector()
end

