# the enum prelude under CRuby, against CRuby's own methods
require_relative "../../lib/indus/rt/enum"
require_relative "../../lib/indus/rt/core" rescue nil
def __ld8(s, i) = s.getbyte(i)
def __st8(s, i, v) = s.setbyte(i, v)
def __salloc(n) = "\0" * n
def __sdup(s) = s.dup
def __trap = raise("trap")
def __hcount(h) = h.size
def __hkey_at(h, i) = h.keys[i]
def __hval_at(h, i) = h.values[i]
def __hkey_p(h, k) = h.key?(k)
def __arr_include_p(a, x) = a.include?(x)
def __arr_uniq(a) = a.uniq
def __arr_take(a, n) = a.take(n)
def __arr_reverse(a) = a.reverse
def __arr_sort(a) = a.sort
def __arr_min(a) = a.min
def __arr_max(a) = a.max
def __str_include_p(s, t) = s.include?(t)
def __str_downcase(s) = s.downcase
def __str_byteslice(s, a, l) = s.byteslice(a, l) || ""
def __str_index_from(s, pat, from) = s.index(pat, from) || -1
def __str_bytes(s) = s.bytes
def __num_abs(n) = n.abs
def check(what, got, want) = (got == want or abort("#{what}: got #{got.inspect} want #{want.inspect}"))
a = [3, 1, 4, 1, 5, 9, 2, 6]
check("each_slice", __arr_each_slice1(a, 3), a.each_slice(3).to_a)
check("each_cons", __arr_each_cons1(a, 3), a.each_cons(3).to_a)
check("zip", __arr_zip([1, 2], ["a", "b"]), [1, 2].zip(["a", "b"]))
check("compact", __arr_compact([1, nil, 2]), [1, 2])
check("rotate", __arr_rotate(a), a.rotate)
check("drop", __arr_drop(a, 3), a.drop(3))
check("last_n", __arr_last1(a, 3), a.last(3))
b = a.dup; check("delete_at", [__arr_delete_at(b, 2), b], [4, a.dup.tap { _1.delete_at(2) }])
b = a.dup; __arr_delete(b, 1); check("delete", b, a - [1])
b = [1, 3]; check("insert", __arr_insert(b, 1, 2), [1, 2, 3])
check("plus", __arr_plus([1], [2, 3]), [1, 2, 3])
check("minus", __arr_minus(a, [1, 9]), a - [1, 9])
check("and", __arr_and([1, 2, 2, 3], [2, 3, 4]), [1, 2, 2, 3] & [2, 3, 4])
check("or", __arr_or([1, 2], [2, 3]), [1, 2] | [2, 3])
check("times", __arr_times([1, 2], 2), [1, 2] * 2)
check("tally", __arr_tally(%w[a b a]), %w[a b a].tally)
check("rindex", __arr_rindex(a, 1), a.rindex(1))
check("product", __arr_product([1, 2], [3]), [1, 2].product([3]))
h = { "a" => 1, "b" => 2 }
check("merge", __hash_merge(h, { "b" => 3, "c" => 4 }), h.merge({ "b" => 3, "c" => 4 }))
check("to_a", __hash_to_a(h), h.to_a)
check("invert", __hash_invert(h), h.invert)
check("minby", __hash_min_by0(h), h.min_by { |k, v| v })
check("lines", __str_lines("a\nb\nc"), "a\nb\nc".lines)
check("squeeze", __str_squeeze("aabbc"), "aabbc".squeeze)
check("delete", __str_delete("hello", "l"), "hello".delete("l"))
check("swapcase", __str_swapcase("aBc"), "aBc".swapcase)
check("chomp", __str_chomp("x\n"), "x\n".chomp)
check("chomp2", __str_chomp("x\r\n"), "x\r\n".chomp)
check("to_f", __str_to_f("3.25"), "3.25".to_f)
check("to_f2", __str_to_f("-12.5"), "-12.5".to_f)
check("hex", __str_hex("ff"), "ff".hex)
check("insert", __str_insert("abc", 1, "X"), "abc".insert(1, "X"))
check("partition", __str_partition("a=b", "="), "a=b".partition("="))
check("gcd", __num_gcd(12, 18), 12.gcd(18))
check("lcm", __num_lcm(4, 6), 4.lcm(6))
check("digits", __num_digits(1234), 1234.digits)
check("bit_length", __num_bit_length(255), 255.bit_length)
check("pow_mod", __num_pow_mod(3, 200, 1000), 3.pow(200, 1000))
check("ceil", __num_ceil(2.1), 2.1.ceil); check("ceil2", __num_ceil(-2.1), -2.1.ceil); check("floor", __num_floor(-2.1), -2.1.floor)
check("divmod", __num_divmod(17, 5), 17.divmod(5))
puts "enum: ok"
