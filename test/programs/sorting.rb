a = [5, 3, 9, 1, 7, 3]
b = a.sort_by { |x| -x }
puts b.inspect
puts a.sort.inspect
puts a.min
puts a.max
words = ["pear", "fig", "banana", "kiwi"]
puts words.sort_by { |w| w.length }.inspect
puts words.min_by { |w| w.length }
puts words.max_by { |w| w.length }
puts [].sort.length
puts a.inspect
