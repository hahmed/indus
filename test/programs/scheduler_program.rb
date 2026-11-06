# a scheduler: time arithmetic, sorting with multiple keys, string padding, ranges
Task = Struct.new(:name, :at, :dur, :prio)
def hhmm(mins) = format("%02d:%02d", mins / 60, mins % 60)
def parse_time(s)
  h, m = s.split(":").map(&:to_i)
  h * 60 + m
end
TASKS = [
  Task.new("standup", parse_time("09:30"), 15, 2),
  Task.new("review", parse_time("09:30"), 45, 1),
  Task.new("deploy", parse_time("16:00"), 30, 1),
  Task.new("lunch", parse_time("12:00"), 60, 3),
  Task.new("1:1", parse_time("11:00"), 30, 2),
]
sorted = TASKS.sort_by { |t| [t.at, t.prio, t.name] }
sorted.each { |t| puts "#{hhmm(t.at)}-#{hhmm(t.at + t.dur)} #{t.name.ljust(10)} p#{t.prio}" }
puts "total #{sorted.sum(&:dur)} min"
clashes = sorted.each_cons(2).select { |(a, b)| a.at + a.dur > b.at }
puts "clashes: #{clashes.map { |(a, b)| "#{a.name}/#{b.name}" }.join(', ')}"
free = []
cursor = parse_time("09:00")
sorted.each do |t|
  free << [cursor, t.at] if t.at > cursor
  cursor = [cursor, t.at + t.dur].max
end
free << [cursor, parse_time("17:00")] if cursor < parse_time("17:00")
free.each { |(s, e)| puts "free #{hhmm(s)}-#{hhmm(e)} (#{e - s})" }
by_prio = TASKS.group_by(&:prio)
by_prio.keys.sort.each { |p| puts "p#{p}: #{by_prio[p].map(&:name).sort.join(' ')}" }
puts TASKS.min_by(&:dur).name, TASKS.max_by(&:dur).name
puts TASKS.count { |t| (parse_time("09:00")..parse_time("12:00")).cover?(t.at) }
