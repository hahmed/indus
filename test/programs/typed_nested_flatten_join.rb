p [[1, 2], [3]].join("-"), [[1, 2], [3, 4]].flatten, [[[1], [2]], [[3]]].flatten
p [nil, nil], [1, 2, 3].max_by(2) { |x| x }, [1, 2, 3].min_by(2) { |x| -x }
