# the Bignum prelude under CRuby, against CRuby's own Integers
require_relative "../../lib/indus/rt/big"
def __trap = raise("trap")
def big(i) = __big_from_int(i)
def check(what, got, want) = (got == want or abort("#{what}: got #{got} want #{want}"))
srand(7)
vals = [0, 1, -1, 2**31, 2**32, 2**32 - 1, 2**62, -(2**62), 12345678901234567890, 3**100, -(7**80), 10**40 + 17]
200.times { vals << rand(-(10**30)..(10**30)) }
vals.each do |a|
  check("to_s #{a}", __big_to_s(big(a)), a.to_s)
  vals.each do |b|
    check("add", __big_to_s(__big_add(big(a), big(b))), (a + b).to_s)
    check("sub", __big_to_s(__big_sub(big(a), big(b))), (a - b).to_s)
    check("mul", __big_to_s(__big_mul(big(a), big(b))), (a * b).to_s)
    check("cmp", __big_cmp(big(a), big(b)), a <=> b)
    next if b == 0
    check("div #{a} #{b}", __big_to_s(__big_div(big(a), big(b))), (a / b).to_s)
    check("mod #{a} #{b}", __big_to_s(__big_mod(big(a), big(b))), (a % b).to_s)
  end
end
# fib(1000) and pidigits-style products
a, b = big(0), big(1)
1000.times { a, b = b, __big_add(a, b) }
f = [0, 1]; 1000.times { f = [f[1], f[0] + f[1]] }
check("fib", __big_to_s(a), f[0].to_s)
puts "big: ok (#{vals.size}^2 pairs)"
