x = [1, "a", nil, true, 2.5, :s, [1], {a: 1}]
p x[6][0], x[7][:a], x.map(&:to_s)
p "abc" << "d" << "e", "hello"[5], "hello"[5, 1], "x".center(6, "ab"), "1.9".succ, :"a b".inspect
p "a\nb".lines(chomp: true), "0x1f".to_i(0), "a".upto("c").to_a, "%3$s %1$s" % ["a", "b", "c"], "%*d|" % [4, 7]
m = "hello".match(/(?<x>l+)(o)/)
p m[:x], m[0]
p proc { |x, y| [x, y] }.call(1), lambda { |x, y = 1| }.arity, proc { |x, y = 1| }.arity
p [1, 2, 3].select.with_index { |x, i| i > 0 }, [1, 2].each.with_object([]) { |x, a| a << x }
p nil | 1, true & 0, true & "s", Array({a: 1}), Hash(nil), 1.class.inspect, :s.respond_to?(:to_s), Object.new.freeze.frozen?, Object.new.instance_of?(Object)
