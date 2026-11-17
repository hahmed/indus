p defined?(nil), defined?(true), defined?(false), defined?(self)
p defined?([NonExistentConstant, Array]), defined?([1, 2]), defined?(Array)
p defined?(x = 1), defined?(@a = 1), defined?($g = 1)
$g = 2; @iv = 3; p defined?($g), defined?(@iv), defined?(@nope), defined?($nope)
def m; end
p defined?(m), defined?(m()), defined?(nope), defined?(puts), defined?(String.new), defined?(1 + 1), defined?(x += 1)
x = 5; p defined?(x), defined?(x.to_s), defined?(NOPE::X), defined?(yield), defined?(super)
p defined?(if 1; end), defined?(1..2), defined?("s"), defined?(:s), defined?(/r/), defined?(1)
p defined?(Object), defined?(Object::NOPE), defined?(String::Comparable), defined?(::Array)
