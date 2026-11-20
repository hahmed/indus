s = "ab"
t = s
u = "ab"
p s.object_id == t.object_id, s.object_id == u.object_id, s.equal?(t), s.equal?(u), 1.object_id, 5.equal?(5), [1].equal?([1])
a = [1]
b = a
p a.equal?(b)
