# breadth batch 3 of lib/indus/rt/enum.rb under CRuby
def __trap = raise("trap")
def __lsr(a, n) = (a & 0xffffffffffffffff) >> n
def __hcount(h) = h.size
def __hkey_at(h, i) = h.keys[i]
def __hval_at(h, i) = h.values[i]
def __hkey_p(h, k) = h.key?(k)
def __arr_sort(a) = a.sort
def __arr_reverse(a) = a.reverse
def __arr_sort_by(a, keys) = a.each_with_index.sort_by { |x, i| keys[i] }.map(&:first)
src = File.read(File.join(__dir__, "../../lib/indus/rt/enum.rb"))
eval(src[src.index("# ---- breadth batch 3")..].sub(/def __hash_delete.*?\nend\n/m, ""))
def check(name, got, want) = got == want ? nil : abort("#{name}: got #{got.inspect}, want #{want.inspect}")
check :transpose, __arr_transpose([[1,2],[3,4]]), [[1,3],[2,4]]
check :cycle, __arr_cycle_first([1,2,3], 5), [1,2,3,1,2]
check :comb, __arr_combination([1,2,3], 2), [1,2,3].combination(2).to_a
check :perm, __arr_permutation([1,2,3], 2), [1,2,3].permutation(2).to_a
check :step, __num_step_to(1, 10, 4), [1,5,9]
check :step_down, __num_step_to(10, 1, -3), [10,7,4,1]
check :values_at, __arr_values_at([1,2,3], [0,2]), [1,3]
check :insert, __arr_insert([1,2,3], 1, 9), [1,9,2,3]
check :insert_neg, __arr_insert([1,2,3], -2, 9), [1,2,9,3]
a = [1,2,3]; check :delete_at, __arr_delete_at(a, 1), 2; check :delete_at_rest, a, [1,3]
check :assoc, __arr_assoc([[1,:a],[2,:b]], 2), [2,:b]
check :rindex, __str_rindex("hello", "l"), 3
%w[abc az zz a9 Az].each { |s| check :"succ #{s}", __str_succ(s), s.succ }
check :hex, __str_hex("0x1f"), 31; check :oct, __str_oct("17"), 15; check :b2, __str_to_i_base("101", 2), 5; check :neg, __str_to_i_base("-ff", 16), -255
check :round_neg, __num_round_int(1234, -2), 1200; check :round_neg2, __num_round_int(1250, -2), 1300; check :round_neg3, __num_round_int(-1250, -2), -1300
check :max_n, __arr_max_n([3,1,2], 2), [3,2]; check :min_n, __arr_min_n([3,1,2], 2), [1,2]
check :sum_str, __arr_sum_str(%w[a bb], ""), "abb"
check :isqrt, __num_isqrt(17), 4; check :isqrt2, __num_isqrt(16), 4; check :isqrt3, __num_isqrt(1), 1
check :digits, __num_digits(255), [5,5,2]; check :bitlen, __num_bit_length(10), 4; check :bitlen_neg, __num_bit_length(-1), 0
check :shuffle_len, __arr_shuffle([1,2,3,4]).sort, [1,2,3,4]
puts "ok"
