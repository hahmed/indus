x = /z/.match("abc")
p x, x.to_a, x.to_s, x.inspect, x.nil?
y = /b/.match("abc")
p y.to_a, y.nil?
