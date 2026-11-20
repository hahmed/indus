p [1, 2] <=> [1, 3], [1, 2] <=> [1, 2], [2] <=> [1, 9], [1, 2] <=> 1
p [1, 2].union([2, 3], [4]), [1, 2].intersect?([2]), [1, 2].intersect?([3]), [1, 2, 3].intersection([2, 3], [3]), [1, 2, 3].difference([1], [3])
p [1, 2].product([3], [4, 5]), [1, 2].product, [1, 2, 3].find_index(2), [1, 2].fetch(1), [1, 2].fetch(5, :d), [[1, [2]]].dig(0, 1)
a = [1, [2, [3]]]
a.flatten!
p a, [1, 2, 3, 4].values_at(0, 2, 3)
begin; [1].fetch(3); rescue IndexError => e; p e.message; end
