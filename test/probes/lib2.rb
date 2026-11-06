n = 42
f = 3.75
neg = -7
big = 12345678901234
p n.to_s, n.to_f, n.to_i, n.abs, neg.abs, n.succ, n.pred, n.even?, n.odd?, n.zero?, 0.zero?, n.positive?, neg.negative?
p n.divmod(5), neg.divmod(5), n.fdiv(5), n.pow(2), n.pow(3, 10), n ** 2, 2 ** 10, 2 ** -1, 2.0 ** 3
p n % 5, neg % 5, n / 5, neg / 5, n.remainder(5), neg.remainder(5), n.modulo(5)
p n.gcd(56), n.lcm(56), n.digits, n.digits(16), n.bit_length, n.to_s(2), n.to_s(16), n.to_s(36)
p n.clamp(1, 10), n.clamp(50, 60), n.between?(1, 100), n <=> 50, n == 42.0, n.eql?(42.0), n.equal?(42)
p n.times.to_a.size, n.times.map { |i| i * 2 }.sum, 3.times.to_a, 5.downto(1).to_a, 1.step(10, 3).to_a, 10.step(1, -4).to_a
p n & 7, n | 1, n ^ 3, ~n, n << 2, n >> 1, n[0], n[1], n[3]
p n.chr, 65.chr, n.ord, n.size, n.hash.is_a?(Integer), n.integer?, f.integer?, n.finite?, f.finite?, (1.0/0).infinite?, (0.0/0.0).nan?
p f.to_i, f.to_s, f.round, f.round(1), f.floor, f.ceil, f.truncate, (-f).round, (-f).floor, (-f).ceil, (-f).truncate, 2.5.round, 3.5.round, -2.5.round
p f.round(-1), 1234.round(-2), 1250.round(-2), 1350.round(-2), f.floor(1), f.ceil(1), 3.14159.round(3), 3.14159.floor(2), 3.14159.ceil(2)
p f.abs, (-f).abs, f.divmod(2), f % 2, f.modulo(2), f.fdiv(2), f / 2, f * 2, f + 1, f - 1, f ** 2, f.quo(2)
p f.nan?, f.zero?, 0.0.zero?, f.positive?, (-f).negative?, f <=> 4, f == 3.75, f.eql?(3.75), f.equal?(f)
p 1e3, 1.5e-3, 1_000_000, 0x1f, 0b101, 0o17, 1.0 / 3, 2.0 / 3, 10.0 / 3, 1e20, 1e-5, 123456789.123456789, 0.1 + 0.2, 100.0, 1e16, 1e15, 12345678912345.0
p Float::INFINITY, -Float::INFINITY, Float::MAX, Float::MIN, Float::EPSILON, Float::NAN.nan?, Float::DIG
p Integer.sqrt(17), Math.sqrt(16), Math.cbrt(27), Math.hypot(3, 4), Math::PI, Math::E, Math.log(Math::E), Math.log2(8), Math.log10(1000), Math.log(8, 2)
p Math.sin(0), Math.cos(0), Math.tan(0), Math.atan(1), Math.atan2(1, 1), Math.exp(1), Math.pow(2, 3) rescue p :nopow
p 10.0.to_i, 10.9.to_i, -10.9.to_i, "10".to_i, "10.5".to_f, "1e3".to_f, "abc".to_i, "12abc".to_i, " 12 ".to_i, "-5".to_i, "+5".to_i, "0x1f".to_i(16), "1f".to_i(16), "z".to_i(36)
p 1.to_r rescue p :nor
p 1.to_c rescue p :noc
p Integer("42"), Float("3.5"), Integer("0x1f", 16) rescue p :noconv
p String(42), Array(nil), Array([1]), Array(1..3), Array("a")
p 7.0 / 2, 7 / 2, 7 % 2, -7 / 2, -7 % 2, 7.divmod(-2), -7.divmod(2), 7.0.divmod(2)
p 5.coerce(2.0), 1.0.coerce(2) rescue p :nocoerce
p rand(1) , rand(1..1), [rand(10)].size, Random.new(42).rand(10).class rescue p :norand
p [1, 2, 3].sum / [1, 2, 3].size, [1, 2, 3].sum.to_f / 3, [1, 2, 3].sum.fdiv(3)
p 10.pred.succ, 3.zero? ? 1 : 2, (1..3).sum { |x| x * x }, 1.upto(4).select(&:even?), 1.upto(4).inject(:*)
p 255.to_s(2).count("1"), 255.digits.sum, 1234.to_s.chars.map(&:to_i).sum, 1234.to_s.reverse.to_i
p 10.0.floor, 10.5.floor, -10.5.floor, 10.5.ceil, -10.5.ceil, 10.5.round, 10.4.round, -10.5.round, 10.5.truncate
p 1.0.to_s, 100.0.to_s, 1.5e10.to_s, 1e100.to_s, 0.000001.to_s, 0.0001.to_s, 123.456.to_s, -0.0.to_s, 1.0e-10.to_s, 2.0e-5.to_s
p 3.7 % 1, -3.7 % 1, 3.7.floor, 7.fdiv(2).ceil, (7 / 2.0).round, 7.0.floor / 2
p "%d" % 3.99, "%f" % 3, "%.1f" % 2.25, "%.1f" % 2.35, "%.0f" % 2.5, "%.0f" % 3.5, "%5.1f|" % 3.14159, "%-8.3f|" % 3.14159, "%e" % 0.000123, "%g" % 0.000123, "%g" % 123456789.0, "%x" % -1 rescue p :nofmt
p "%s" % nil, "%s" % [[1, 2]], "%p" % [nil], "%p" % ["a"], "%-5s|" % "ab", "%5s|" % "ab", "%05.1f" % 3.14159, "%+.2f" % 3.14159, "% d" % 5, "%03d" % -5, "%x" % 255, "%X" % 255, "%#x" % 255, "%o" % 8, "%b" % 10, "%08b" % 10, "%c" % "a", "%%"
p format("%-10s%5d", "item", 3), format("%.3e", 12345.6789), format("%10.2f", 3.14159), format("%s", :sym), format("%d%%", 50)
p 1 <=> 2, 2 <=> 1, 1 <=> 1, 1 <=> "a", "a" <=> 1, nil <=> nil, nil <=> 1, [1, 2] <=> [1, 3], [1, 2] <=> [1, 2, 3]
p 1.clamp(2, 3), 5.clamp(2, 3), 2.5.clamp(1, 2), "b".clamp("a", "c"), 1.clamp(..0), 5.clamp(3..) rescue p :noclamp
p [3, 1, 2].max(2), [3, 1, 2].min(2), [3, 1, 2].minmax, %w[bb a ccc].max_by(&:size), %w[bb a ccc].min_by(&:size), %w[bb a ccc].sort_by(&:size), %w[bb a ccc].max, [1, 2.5].max, [1, 2.5].sum
p 1.integer?, 1.5.integer?, 1.is_a?(Integer), 1.is_a?(Numeric), 1.5.is_a?(Float), 1.is_a?(Comparable), 1.kind_of?(Integer), 1.instance_of?(Integer), 1.class, 1.5.class, nil.class, true.class, :a.class, "a".class, [].class, {}.class, (1..2).class, 1.0.class.name
p nil.to_a, nil.to_s, nil.to_i, nil.inspect, nil & true, nil | true, nil.nil?, NilClass, true & false, true | false, true ^ true, false ^ true, !true, !!nil, true.to_s, false.inspect, true == true, nil == false
p :abc.to_s, :abc.length, :abc.size, :abc.to_proc.call("x") rescue p :nosymproc
p :abc <=> :abd, :abc == :abc, :abc.inspect, :"with space".inspect, :abc.upcase, :abc.succ, :a.to_sym, "a".to_sym, :abc[0], :abc.start_with?("ab"), :abc.end_with?("c"), %i[a b].include?(:a), %i[b a].sort, :abc.hash.is_a?(Integer)
p defined?(x), defined?(n), defined?(puts), defined?(String), defined?(@iv), defined?(yield), defined?(super) rescue p :nodefined
p __method__.inspect, __FILE__.class, __LINE__.class, __dir__.class rescue p :nometa
p [1, 2, 3].frozen?, "a".frozen?, :a.frozen?, 1.frozen?, nil.frozen?, "a".dup.frozen?, [1].freeze.frozen? rescue p :nofrozen
p 1.object_id.is_a?(Integer), nil.object_id, true.object_id, 1.object_id, 2.object_id, :a.object_id.is_a?(Integer) rescue p :noobjid
p 10.digits.reverse.join.to_i, 100.to_s.rjust(5, "0"), 7.to_s.ljust(3, "x"), 42.to_s.center(6, "-"), 65.chr * 3, 1.0.to_i.to_s * 2
p (1..Float::INFINITY).lazy.map { |x| x * 2 }.first(3) rescue p :nolazy
p 1.step(2, 0.5).to_a, 1.0.step(2.0, 0.5).to_a, (1.0..2.0).step(0.5).to_a, 0.step(by: 2, to: 6).to_a rescue p :nostepf
p Comparable.instance_method(:clamp).class rescue p :noinstmeth
p 3.14.to_r.class rescue p :nor2
p 1234567.to_s.reverse.scan(/\d{1,3}/).join(",").reverse, 1234567.to_s.gsub(/(\d)(?=(\d{3})+$)/, "\\1,") rescue p :nolook
p 1234567.to_s.chars.reverse.each_slice(3).map(&:join).join(",").reverse
p 0.1 * 3, 0.1 * 3 == 0.3, (0.1 * 3 - 0.3).abs < Float::EPSILON, 1.0.eql?(1), 1 == 1.0, 1.eql?(1), 1.equal?(1), 1.0.equal?(1.0), 3.0 * 1.1, 1.1 + 2.2, 1e308 * 10, -1e308 * 10, 0.0 / 0.0 == 0.0 / 0.0, 2 ** 62, 2 ** 63, 2 ** 64, -(2 ** 63), 4611686018427387904.class, 9223372036854775807 + 1, 18446744073709551616.to_s.length, (2 ** 100).to_s, 10 ** 20, 10 ** 20 / 10 ** 10, (10 ** 20) % 7, 10 ** 20 > 10 ** 19, (2 ** 64).bit_length, (2 ** 64) >> 60, 123456789 * 987654321, 123456789 * 987654321 * 1000, (12345678901234 * 98765432109876).to_s
