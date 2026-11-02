h = {"a" => 1, "b" => 2}
h["c"] = 3
puts h["a"] + h["b"] + h["c"]
puts h.key?("b")
puts h.key?("z")
puts h["z"]
i = 0
while i < 100
  h["k" + i.to_s] = i
  i = i + 1
end
puts h.keys.length
puts h["k57"]
m = {}
m[5] = 50
m[7] = 70
puts m[5] + m[7]
w = ["the", "of", "and"]
puts w[1]
s = "hello"
puts s[1]
puts s[1, 3]
puts s[0] == "h"
