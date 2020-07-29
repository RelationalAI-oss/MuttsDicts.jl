function Base.merge!(
    combine::Function,
    d::MuttsDict,
    others::Union{MuttsDict,AbstractDict}...,
)
    for other in others
        for (k,v) in other
            if haskey(d, k)
                d[k] = combine(d[k], v)
            else
                d[k] = v
            end
        end
    end
    return d
end

function Base.merge!(d::MuttsDict, others::Union{MuttsDict,AbstractDict}...)
    for other in others
        for (k,v) in other
            d[k] = v
        end
    end
    return d
end

function Base.merge(d::MuttsDict, others::Union{MuttsDict,AbstractDict}...)
    result = branch!(d)
    Base.merge!(result, others...)
    mark_immutable!(result)
    return result
end
