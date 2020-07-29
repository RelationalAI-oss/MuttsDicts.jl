function leaf_bytes(seen::Set{UInt64}, inode::INode{K,V}) where {K,V}
    id = objectid(inode)
    in(id, seen) && return 0
    push!(seen, id)
    n = 0
    for child in inode.entries
        n += leaf_bytes(seen, child)
    end
    return n
end

function leaf_bytes(seen::Set{UInt64}, leaf::Leaf{K,V}) where {K,V}
    id = objectid(leaf)
    in(id, seen) && return 0
    push!(seen, id)
    n = Base.summarysize(leaf)
    if length(leaf.big_slots) == 0
        n -= Base.summarysize(leaf.big_slots)
    end
    return n
end

function dump_tree(seen::Set{UInt64}, prefix::String, inode::INode{K,V}) where {K,V}
    id = objectid(inode)
    if in(id,seen)
        sflag="*"
    else
        push!(seen, id)
        sflag=" "
    end

    count=0
    for i=1:length(inode.entries)
        child_prefix = "$(prefix)$(i-1)|"
        count += dump_tree(seen, child_prefix, inode.entries[i])
    end
    println("$(sflag) $(prefix) \t\t$(count)")
    sflag=="*" && return 0
    return count
end

function dump_tree(seen::Set{UInt64}, prefix::String, leaf::Leaf{K,V}) where {K,V}
    id = objectid(leaf)
    if in(id,seen)
        sflag="*"
    else
        push!(seen, id)
        sflag=" "
    end

    count=0
    num_slots = length(leaf.entries)
    for i=1:num_slots
        if _slot_occupied(leaf, UInt64(i), num_slots)
            count += 1
        end
    end
    println("$(sflag) $(prefix) $(count) in $(num_slots) slots")
    sflag=="*" && return 0
    return count
end
