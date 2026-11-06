# an ini/config parser with defaults, symbol keys, nested access, freeze-free
class Config
  DEFAULTS = { "port" => "8080", "host" => "localhost", "debug" => "false" }
  def initialize(text)
    @sections = { "global" => DEFAULTS.dup }
    section = "global"
    text.each_line do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      if line =~ /\A\[(.+)\]\z/
        section = $1
        @sections[section] ||= {}
      elsif line =~ /\A([\w.]+)\s*=\s*(.*)\z/
        @sections[section][$1] = $2
      else
        warn_bad(line)
      end
    end
  end
  def warn_bad(line) = (@bad ||= []) << line
  def bad = @bad || []
  def [](section) = @sections[section] || {}
  def get(section, key, default = nil)
    s = @sections[section]
    return default if s.nil?
    s.fetch(key) { default }
  end
  def int(section, key, default = 0) = get(section, key, default.to_s).to_i
  def bool?(section, key) = get(section, key, "false") == "true"
  def sections = @sections.keys.sort
end

text = <<~INI
  # comment
  port = 9090
  debug = true

  [db]
  host = db.local
  pool = 5
  bogus line here

  [cache]
  ttl = 300
INI
c = Config.new(text)
puts c.sections.inspect
puts c.int("global", "port")
puts c.bool?("global", "debug")
puts c["db"]["host"]
puts c.int("db", "pool")
puts c.int("cache", "ttl")
puts c.get("nope", "x", "fallback")
puts c.int("db", "missing", 42)
puts c.bad.inspect
puts c["global"]["host"]
