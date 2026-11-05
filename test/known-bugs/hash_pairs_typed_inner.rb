h = {2 => [10]}
puts h.to_a.inspect
# KNOWN BUG (found by test/fuzz, seed 3): prints [[2, [false]]], CRuby prints [[2, [10]]].
# A hash whose values are typed arrays, read as pairs: __hash_to_a boxes the inner array
# with tag 4, which claims tagged elements, but the array still holds raw ints, so the
# reader of the tag decodes 10 as a tagged value (tag 10 = false).
# The fix is a conversion where a typed container enters a tagged slot (a copy whose
# elements are tagged). The attempt failed because the conversion is inserted after the
# type fixpoint, so the copier itself never gets typed; it needs to be inserted during
# typing (where each_flow sees the dest), not in convert.
