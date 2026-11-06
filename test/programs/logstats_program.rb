# log aggregation: parse, group, summarise, format a table
LOG = [
  "2024-01-01 10:00:00 INFO  api  request ok 120",
  "2024-01-01 10:00:01 WARN  api  slow response 850",
  "2024-01-01 10:00:02 ERROR db   timeout 3000",
  "2024-01-01 10:00:05 INFO  api  request ok 95",
  "2024-01-01 10:00:07 ERROR api  bad gateway 500",
  "2024-01-01 10:01:00 INFO  db   query ok 40",
  "garbage line",
]
Entry = Struct.new(:time, :level, :comp, :msg, :ms)
entries = LOG.filter_map do |line|
  next unless line =~ /^(\S+ \S+) (\w+)\s+(\w+)\s+(.+?) (\d+)$/
  Entry.new($1, $2, $3, $4, $5.to_i)
end
puts entries.size
by_comp = entries.group_by(&:comp)
by_comp.keys.sort.each do |comp|
  rows = by_comp[comp]
  total = rows.sum(&:ms)
  worst = rows.max_by(&:ms)
  puts format("%-4s n=%d total=%5dms avg=%6.1f worst=%s", comp, rows.size, total, total.to_f / rows.size, worst.msg)
end
levels = entries.each_with_object(Hash.new(0)) { |e, h| h[e.level] += 1 }
puts levels.sort.map { |k, v| "#{k}:#{v}" }.join(" ")
errors = entries.select { |e| e.level == "ERROR" }.map(&:msg).sort
puts errors.inspect
slow = entries.sort_by { |e| -e.ms }.first(3).map { |e| "#{e.comp}/#{e.ms}" }
puts slow.inspect
puts entries.map(&:ms).minmax.inspect
puts entries.count { |e| e.ms > 100 }
puts entries.any? { |e| e.level == "FATAL" }
puts entries.partition { |e| e.comp == "api" }.map(&:size).inspect
