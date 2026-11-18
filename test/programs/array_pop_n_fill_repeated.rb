a = [1, 2, 3, 4, 5]
p a.pop(2); p a; p a.shift(2); p a; p a.slice!(0); p a
p [1, 2, 3].slice!(0, 2), [1, 2, 3].at(-1), [1, 2, 3].rotate!, [1, 2, 3].rotate!(2)
p [0, 0, 0, 0].fill(7, 2), [0, 0, 0, 0].fill(7, 1, 2), [1, 2].repeated_combination(2).to_a, [1, 2].repeated_permutation(2).to_a, [[1, :a], [2, :b]].rassoc(:b), { x: 1, y: 2 }.rassoc(2)
p 7.div(2), -7.div(2), 7.0.div(2), 6.gcdlcm(4), 1.coerce(2)
p [1, 2, 3].sample(2).size
