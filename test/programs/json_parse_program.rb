# a JSON parser (string scanning, recursion, mixed containers)
class JSON
  def self.parse(s) = new(s).value
  def initialize(s) = (@s = s; @i = 0)
  def ws = (@i += 1 while @i < @s.length && " \t\n\r".include?(@s[@i]))
  def value
    ws
    c = @s[@i]
    case c
    when "{" then object
    when "[" then array
    when "\"" then string
    when "t" then (@i += 4; true)
    when "f" then (@i += 5; false)
    when "n" then (@i += 4; nil)
    else number
    end
  end
  def object
    @i += 1
    h = {}
    ws
    if @s[@i] == "}"
      @i += 1
      return h
    end
    loop do
      ws
      k = string
      ws
      @i += 1 # :
      h[k] = value
      ws
      if @s[@i] == ","
        @i += 1
      else
        @i += 1
        break
      end
    end
    h
  end
  def array
    @i += 1
    a = []
    ws
    if @s[@i] == "]"
      @i += 1
      return a
    end
    loop do
      a << value
      ws
      if @s[@i] == ","
        @i += 1
      else
        @i += 1
        break
      end
    end
    a
  end
  def string
    @i += 1
    out = +""
    while @s[@i] != "\""
      if @s[@i] == "\\"
        @i += 1
        c = @s[@i]
        out << (c == "n" ? "\n" : c == "t" ? "\t" : c)
      else
        out << @s[@i]
      end
      @i += 1
    end
    @i += 1
    out
  end
  def number
    start = @i
    @i += 1 while @i < @s.length && "-+.eE0123456789".include?(@s[@i])
    t = @s[start, @i - start]
    t.include?(".") || t.include?("e") ? t.to_f : t.to_i
  end
end

doc = "{\"name\": \"indus\", \"version\": 2, \"ratio\": 0.75, \"tags\": [\"a\", \"b\"], \"ok\": true, \"nil\": null, \"nested\": {\"x\": [1, 2, {\"y\": 3}]}}"
v = JSON.parse(doc)
puts v["name"]
puts v["version"] + 1
puts v["ratio"] * 4
puts v["tags"].inspect
puts v["ok"].inspect, v["nil"].inspect
puts v["nested"]["x"].length
puts JSON.parse("[1, 2, 3]").sum
puts JSON.parse("\"esc\\ttab\"")
puts JSON.parse("{}").inspect, JSON.parse("[]").inspect
