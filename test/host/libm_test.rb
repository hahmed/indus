# the standalone Math (lib/indus/rt/libm.rb) under CRuby, against libm: ulp distance
def __fbits(f) = [f].pack("G").unpack1("Q>")
def __ffrom(b) = [b].pack("Q>").unpack1("G")
def __trap = raise("trap")
def __wshl(a, n) = ((a << n) & 0xffffffffffffffff).then { _1 >= 1 << 63 ? _1 - (1 << 64) : _1 }
def __wadd(a, b) = ((a + b) & 0xffffffffffffffff).then { _1 >= 1 << 63 ? _1 - (1 << 64) : _1 }
def __lsr(a, n) = (a & 0xffffffffffffffff) >> n
def __umulh(a, b) = ((a & 0xffffffffffffffff) * (b & 0xffffffffffffffff)) >> 64
def __wmul(a, b) = (((a & 0xffffffffffffffff) * (b & 0xffffffffffffffff)) & 0xffffffffffffffff).then { _1 >= 1 << 63 ? _1 - (1 << 64) : _1 }
require_relative "../../lib/indus/rt/libm"

def ulps(a, b)
  return 0 if a == b
  return 1_000_000 if a.nan? != b.nan?
  (__fbits(a) - __fbits(b)).abs
end

worst = Hash.new(0)
rng = Random.new(7)
20_000.times do
  x = (rng.rand - 0.5) * 2000.0
  worst[:sin] = [worst[:sin], ulps(__libm_sin(x), Math.sin(x))].max
  worst[:cos] = [worst[:cos], ulps(__libm_cos(x), Math.cos(x))].max
  e = (rng.rand - 0.5) * 1400.0
  worst[:exp] = [worst[:exp], ulps(__libm_exp(e), Math.exp(e))].max
  l = rng.rand * 1.0e6 + 1.0e-6
  worst[:log] = [worst[:log], ulps(__libm_log(l), Math.log(l))].max
  b = rng.rand * 50.0 + 0.01
  p_ = (rng.rand - 0.5) * 40.0
  worst[:pow] = [worst[:pow], ulps(__libm_pow(b, p_), b**p_)].max
  worst[:pow_int] = [worst[:pow_int], ulps(__libm_pow(b, p_.round.to_f), b**p_.round)].max
end
[0.0, -0.0, 1.0e-300, 3.141592653589793, 1.5707963267948966, 1.0e5].each do |x|
  worst[:sin_edge] = [worst[:sin_edge], ulps(__libm_sin(x), Math.sin(x))].max
end
2000.times do
  x = (rng.rand - 0.5) * 2.0 * 10.0 ** rng.rand(7..18)
  worst[:sin_large] = [worst[:sin_large], ulps(__libm_sin(x), Math.sin(x))].max
  worst[:cos_large] = [worst[:cos_large], ulps(__libm_cos(x), Math.cos(x))].max
end
[2500000.0, 3000000.0, 1.0e10, 1.0e15, 1.0e18].each { |x| worst[:sin_large] = [worst[:sin_large], ulps(__libm_sin(x), Math.sin(x))].max }
worst.each { |k, v| puts "#{k}: #{v} ulp" }
bad = worst.select { |k, v| v > (k == :pow ? 128 : k == :pow_int ? 16 : k.to_s.end_with?("large") ? 2 : 1) } # pow is exp(y log x): the log error times y; ~1e-14 relative
abort "too inaccurate: #{bad.inspect}" unless bad.empty?
puts "ok"
w2 = w10 = 0
5000.times { x = rng.rand * 10.0 ** rng.rand(-5..8); w2 = [w2, ulps(__libm_log2(x), Math.log2(x))].max; w10 = [w10, ulps(__libm_log10(x), Math.log10(x))].max }
[1.0, 2.0, 8.0, 1024.0, 10.0, 100.0, 1000.0, 1.0e6].each { |x| w2 = [w2, ulps(__libm_log2(x), Math.log2(x))].max; w10 = [w10, ulps(__libm_log10(x), Math.log10(x))].max }
puts "log2: #{w2} ulp, log10: #{w10} ulp"
abort "log2/log10 inaccurate" if w2 > 2 || w10 > 1 # log2: k + l/ln2 rounds twice
