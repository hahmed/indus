# a small JSON-ish serializer / pretty printer without regexps
module Json
  def self.dump(v, indent = 0)
    pad = "  " * indent
    case v
    when Hash
      return "{}" if v.empty?
      inner = v.map { |k, val| "#{pad}  \"#{k}\": #{dump(val, indent + 1)}" }
      "{\n" + inner.join(",\n") + "\n#{pad}}"
    when Array
      return "[]" if v.empty?
      "[" + v.map { |x| dump(x, indent + 1) }.join(", ") + "]"
    when String then "\"" + escape(v) + "\""
    when Integer, Float then v.to_s
    when true then "true"
    when false then "false"
    when nil then "null"
    when Symbol then "\"#{v}\""
    else raise ArgumentError, "cannot dump #{v.class}"
    end
  end

  def self.escape(s)
    out = +""
    s.each_char do |c|
      case c
      when "\"" then out << "\\\""
      when "\\" then out << "\\\\"
      when "\n" then out << "\\n"
      when "\t" then out << "\\t"
      else out << c
      end
    end
    out
  end
end

doc = {
  "name" => "indus",
  "version" => [0, 5, 2],
  "tags" => %w[ruby compiler arm64],
  "stable" => false,
  "ratio" => 0.75,
  "nested" => { "a" => 1, "b" => { "c" => [1, 2, { "d" => nil }] } },
  "quote" => "she said \"hi\"\n",
  "sym" => :ok,
}
puts Json.dump(doc)
puts Json.dump([])
puts Json.dump({})
puts Json.dump([1, [2, [3, "x"]]])
begin
  Json.dump(Object.new)
rescue ArgumentError => e
  puts "error: #{e.message}"
end
