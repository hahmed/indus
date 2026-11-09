m = "john@example.com".match(/(\w+)@(\w+)\.com/)
p m[1], m[2], m[0], m.captures, m.pre_match, m.to_a.size
n = "id=42".match(/(?<key>\w+)=(?<val>\d+)/)
p n[:key], n["val"], n.names, n.named_captures, n.begin(0), n.end(:val)
p n
p "x".match(/\d/)
if (mm = "2024-05-06".match(/(\d+)-(\d+)-(\d+)/)) then p mm.captures.map(&:to_i) end
