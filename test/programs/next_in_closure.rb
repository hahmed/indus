p(-> { 123; next; 456 }.call)
p(-> { next 7; 456 }.call)
pr = proc { |x| next x * 2 if x > 1; 0 }
p pr.call(5), pr.call(1)
