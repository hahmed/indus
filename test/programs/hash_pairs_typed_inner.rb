h = {2 => [10]}
h.each { |k, v| puts v.inspect }
puts h.map { |k, v| [k, v] }.inspect
puts h.to_a.inspect
puts({"a" => [1,2], "b" => []}.to_a.inspect)
puts({1 => "x"}.to_a.inspect)
puts([[1, [2]], [3, [4]]].to_h.to_a.inspect)
