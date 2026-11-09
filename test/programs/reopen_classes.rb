class A; def a = 1; end
class A; def b = 2; attr_accessor :x; end
class A; def initialize = @x = 5; def y = @y ||= 7; end
a = A.new; p a.a, a.b, a.x, a.y, a.y
class String; def shout = upcase + "!"; def blank? = strip.empty?; end
class Integer; def minutes = self * 60; end
class Array; def second = self[1]; end
class Hash; def symbolize = transform_keys(&:to_sym); end
p "hi".shout, " ".blank?, 2.minutes, [1, 2].second, { "a" => 1 }.symbolize
