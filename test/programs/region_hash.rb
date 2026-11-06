rows = []
i = 0
while i < 1000
  h = { "id" => i.to_s, "name" => "user" + i.to_s, "tags" => ["a", "b" + i.to_s] }
  rows << h if i % 50 == 0
  i += 1
end
rows.each { |h| puts "#{h["id"]} #{h["name"]} #{h["tags"].join(",")}" }
puts rows.size
