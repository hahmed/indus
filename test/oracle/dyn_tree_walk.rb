def walk(tree, out)
  return if tree.nil?
  walk(tree[1], out)
  out << tree[0]
  walk(tree[2], out)
end
t = [5, [3, nil, nil], nil]
acc = []
walk(t, acc)
puts acc.inspect
