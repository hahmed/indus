s = "tel: 555-1234, alt 555-9876"
puts s =~ /\d{3}-\d{4}/
puts s.scan(/\d{3}-\d{4}/).inspect
puts s.gsub(/\d/, "#")
puts s.sub(/(\d+)-(\d+)/, "\\2-\\1")
if s =~ /alt (\d+)/
  puts $1
end
m = "john@example.com".match(/(\w+)@(\w+)\.com/)
puts m[1], m[2]
puts "a, b,c".split(/\s*,\s*/).inspect
puts "Hello".match?(/^h/i)
puts "x".match?(/y/)
puts "2024-01-15".scan(/\d+/).map(&:to_i).sum
