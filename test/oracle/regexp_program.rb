lines = ["GET /index.html 200", "POST /api/users 201", "GET /missing 404", "bad line"]
counts = Hash.new(0)
lines.each do |l|
  if l =~ /^(GET|POST) (\S+) (\d{3})$/
    counts[$3[0]] += 1
    puts "#{$1.downcase} #{$2} -> #{$3}"
  else
    puts "unparsed: #{l}"
  end
end
puts counts.sort.inspect
def classify(w)
  case w
  when /^\d+$/ then "number"
  when /^[A-Z]/ then "proper"
  when /^\w+$/ then "word"
  else "other"
  end
end
puts %w[42 Ruby hello a-b].map { |w| classify(w) }.inspect
csv = "name, age ,city"
puts csv.split(/\s*,\s*/).inspect
puts "CamelCaseString".gsub(/([A-Z])/) { |m| "_" + m.downcase } rescue puts "gsub-block unsupported"
puts "hello world".gsub(/o/, "0")
puts "a1b2c3".scan(/[a-z]\d/).inspect
puts "The quick brown".scan(/\b\w/).join
puts "2024-03-15" =~ /(\d+)-(\d+)-(\d+)/ ? "#{$3}/#{$2}/#{$1}" : "no"
email = "user@example.org"
puts email.match?(/\A[\w.+-]+@[\w-]+\.\w+\z/)
puts "aaa".sub(/a/, "b"), "aaa".gsub(/a/, "b")
puts "x".sub(/y/, "z")
