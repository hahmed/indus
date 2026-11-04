File.open("/tmp/indus_io_test.txt", "w") do |f|
  i = 0
  while i < 5
    f.puts("line " + i.to_s)
    i = i + 1
  end
  f.write("tail")
end
n = 0
File.open("/tmp/indus_io_test.txt", "r") do |f|
  f.each_line do |line|
    n = n + 1
    puts line.strip + "|"
  end
end
puts n
File.delete("/tmp/indus_io_test.txt")
puts "done"
