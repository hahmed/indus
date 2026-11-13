pr = proc { |a, b| [a, b] }
p pr.call([1, 2]), pr.call(3, 4), pr.call([5])
pr = proc do |a, (*), b|
  [a, b]
end
p pr.call([1, 2, 3])
pr = proc { |a, (b, *), c| [a, b, c] }
p pr.call(1, [2, 3, 4], 5)
pr2 = proc { |(x, *y)| [x, y] }
p pr2.call([1, 2, 3])
