# MuttsDicts.jl
Versioned dictionaries following the mutable-until-shared (Mutts) discipline

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
