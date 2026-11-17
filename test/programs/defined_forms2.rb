class B; def pm = 1; protected :pm; end
def um; end
p defined?(B.new.pm), defined?(Kernel.nope_m), defined?(nope_local.foo), defined?(Nope.foo), defined?(B.new.nope)
p defined?($&), defined?($`), defined?($'), defined?($1), defined?($~), defined?($!)
p defined?((a, b = 1, 2)), defined?(Object::A += 1), defined?(@@a ||= true), defined?(X::Y = 1), defined?(Q = 1), defined?(@iv ||= 2), defined?($gg &&= 3)
