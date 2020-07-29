# The branching factors for the various INode levels, as determined by
# _config_for_size(N). A NodeConfig remains valid until the number of dictionary
# entries N reaches next_config_size - changing configurations is handled by
# insert!(dict,h,k,v).
struct NodeConfig
    inode_capacity::Vector{Int}
    next_config_size::Int
end

function _config_for_size2(N::Int)::NodeConfig
    if N < 16
        return NodeConfig(Int64[], 16)
    elseif N < 65536
        # For small dictionaries, use inode_capacity=4, and height increasing with N.
        num_bits = ceil(log2(N+1))
        leaf_bits = min(num_bits,4)
        num_inodes = max(1, convert(Int, ceil((num_bits-leaf_bits)/2)))
        inode_capacity = [4 for i in 1:num_inodes]
        next_config_size = 2^(4+2*(num_inodes))
    else
        # For large dictionaries, we use height 7, and inode capacity increasing with
        # N.  We partition ceil(log2(N)) bits among 7 levels, and to grow capacity as
        # N increases we add a single bit to one level.

        # We will have 1/7 of the bits at the leaf node, so 6/7 of the bits will be
        # partitioned among the inodes.  We start by giving all levels the same number
        # of bits, then take care of the remainder by putting one extra bit at deeper
        # levels.
        num_bits = ceil(log2(N+1))
        leaf_bits = max(4, convert(Int, floor(num_bits/7)))
        inode_bits = num_bits - leaf_bits
        m = convert(Int, floor(inode_bits/6))
        inode_capacity = [2^m for i in 1:6]
        have_bits = m*6
        for k=6:-1:1
            if have_bits < inode_bits
                inode_capacity[k] *= 2
                @dassert1 inode_capacity[k] <= 256   # N <= 2^56
                have_bits += 1
            else
                break
            end
        end
        next_config_size = convert(Int, 2^(floor(log2(N))+1))
    end
    shifts = [0 for i in 1:6]
    return NodeConfig(inode_capacity, next_config_size)
end

const config1 = _config_for_size2(1)
const config16 = _config_for_size2(16)
const config64 = _config_for_size2(64)
const config256 = _config_for_size2(256)

function _config_for_size(N::Int)::NodeConfig
    # For N < 1024, use one of the pre-allocated instances config1/config16/
    # config64/config256, to reduce space use by small dictionaries.
    if N < 64
        if N < 16
            @dassert1 config1.next_config_size == 16
            return config1
        else
            @dassert1 config16.next_config_size == 64
            return config16
        end
    elseif N < 1024
        if N < 256
            @dassert1 config64.next_config_size == 256
            return config64
        else
            @dassert1 config256.next_config_size == 1024
            return config256
        end
    else
        return _config_for_size2(N)
    end
end
