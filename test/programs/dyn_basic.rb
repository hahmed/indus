cells = []
cells.push("hello")
cells.push(42)
cells.push([1, 2, 3])
cells.push(nil)
cells.push(true)
cells.push(2.5)
puts cells.length
i = 0
while i < cells.length
  v = cells[i]
  if v.is_a?(String)
    puts "str:" + v
  elsif v.is_a?(Integer)
    puts v + 1
  elsif v.is_a?(Array)
    puts v.length
  elsif v.nil?
    puts "nil!"
  elsif v.is_a?(Float)
    puts v * 2
  else
    puts "other"
  end
  i = i + 1
end
x = 5
x = "five" if cells.length > 3
puts x.is_a?(String)
p cells
