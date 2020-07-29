# To disable debug assertions, change DASSERT_LEVEL to `0` in your environment
# and re-compile.  To enable more aggressive debug assertions, change
# DASSERT_LEVEL to `2` (or higher).

function _assert_level()
    if haskey(ENV, "DASSERT_LEVEL")
        return parse(Int, ENV["DASSERT_LEVEL"])
    else
        return 1
    end
end

const DASSERT_LEVEL = _assert_level()

macro dassert1(ex, msgs...)
    if DASSERT_LEVEL ≥ 1
        esc(:(@assert($ex, $(msgs...))))
    else
        :(nothing)
    end
end

export @dassert1

