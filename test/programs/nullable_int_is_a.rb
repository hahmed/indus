x = [1][5]; p x.is_a?(Integer), x.nil?, x.is_a?(NilClass), x.is_a?(Object)
y = [1][0]; p y.is_a?(Integer), y.is_a?(NilClass)
puts [1, 2.5].map(&:to_s).join(",")
