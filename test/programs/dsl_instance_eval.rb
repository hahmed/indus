class Config
  attr_reader :name, :ports, :opts
  def initialize = (@ports = []; @opts = {})
  def name(v = nil) = v ? (@name = v) : @name
  def port(p) = @ports << p
  def set(k, v) = @opts[k] = v
  def self.build(&blk)
    c = new
    c.instance_eval(&blk)
    c
  end
  def configure(&blk) = (instance_exec(self, &blk); self)
end
base = 8000
cfg = Config.build do
  name "web"
  port base + 80
  port base + 443
  set :tls, true
end
p cfg.name, cfg.ports, cfg.opts
cfg.configure { |c| port 1; set :debug, c.ports.size }
p cfg.ports, cfg.opts
