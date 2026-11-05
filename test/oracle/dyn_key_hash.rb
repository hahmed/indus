h = {}
k1 = ["ab", 1][0]
k2 = ["a" + "b", 1][0]
h[k1] = 1
puts h[k2]
puts h.key?("ab")
