# Array / Hash methods in Ruby, routed by name (__arr_*, __hash_*). Blocks are
# lowered separately; these are the block-less forms and the ones a block
# cannot express. Host-tested against CRuby in test/host/enum_test.rb.

def __arr_each_slice1(a, n)
  out = []
  i = 0
  while i < a.length
    out.push(a[i, n])
    i = i + n
  end
  out
end

def __arr_each_cons1(a, n)
  out = []
  i = 0
  while i + n <= a.length
    out.push(a[i, n])
    i = i + 1
  end
  out
end

def __arr_zip(a, b)
  out = []
  i = 0
  while i < a.length
    out.push([a[i], b[i]])
    i = i + 1
  end
  out
end

def __arr_compact(a)
  out = []
  i = 0
  while i < a.length
    out.push(a[i]) unless a[i].nil?
    i = i + 1
  end
  out
end

def __arr_rotate(a)
  out = []
  i = 1
  while i < a.length
    out.push(a[i])
    i = i + 1
  end
  out.push(a[0]) if a.length > 0
  out
end

def __arr_drop(a, n)
  out = []
  i = n
  while i < a.length
    out.push(a[i])
    i = i + 1
  end
  out
end

def __arr_last1(a, n)
  start = a.length - n
  start = 0 if start < 0
  __arr_drop(a, start)
end

def __arr_first1(a, n) = __arr_take(a, n)

def __arr_delete_at(a, i)
  return nil if i < 0 || i >= a.length
  v = a[i]
  j = i
  while j < a.length - 1
    a[j] = a[j + 1]
    j = j + 1
  end
  a.pop
  v
end

def __arr_delete(a, x)
  i = 0
  found = nil
  while i < a.length
    if a[i] == x
      found = __arr_delete_at(a, i)
    else
      i = i + 1
    end
  end
  found
end

def __arr_insert(a, i, x)
  a.push(x)
  j = a.length - 1
  while j > i
    a[j] = a[j - 1]
    j = j - 1
  end
  a[i] = x
  a
end

def __arr_unshift(a, x) = __arr_insert(a, 0, x)

def __arr_count(a) = a.length

def __arr_minmax(a) = [__arr_min(a), __arr_max(a)]

def __arr_sum_f(a)
  t = 0.0
  i = 0
  while i < a.length
    t = t + a[i]
    i = i + 1
  end
  t
end

def __arr_product(a, b)
  out = []
  i = 0
  while i < a.length
    j = 0
    while j < b.length
      out.push([a[i], b[j]])
      j = j + 1
    end
    i = i + 1
  end
  out
end

def __arr_sort_desc(a) = __arr_reverse(__arr_sort(a))

def __arr_sample(a) = a[0]

def __arr_plus(a, b)
  out = []
  i = 0
  while i < a.length
    out.push(a[i])
    i = i + 1
  end
  i = 0
  while i < b.length
    out.push(b[i])
    i = i + 1
  end
  out
end

def __arr_minus(a, b)
  out = []
  i = 0
  while i < a.length
    out.push(a[i]) unless __arr_include_p(b, a[i])
    i = i + 1
  end
  out
end

def __arr_and(a, b)
  out = []
  i = 0
  while i < a.length
    out.push(a[i]) if __arr_include_p(b, a[i]) && !__arr_include_p(out, a[i])
    i = i + 1
  end
  out
end

def __arr_or(a, b) = __arr_uniq(__arr_plus(a, b))

def __arr_times(a, n)
  out = []
  k = 0
  while k < n
    out = __arr_plus(out, a)
    k = k + 1
  end
  out
end

def __arr_clear(a)
  a.pop while a.length > 0
  a
end

def __arr_fill(a, v)
  i = 0
  while i < a.length
    a[i] = v
    i = i + 1
  end
  a
end

def __arr_tally(a)
  h = {}
  i = 0
  while i < a.length
    h[a[i]] = (__hkey_p(h, a[i]) ? h[a[i]] : 0) + 1
    i = i + 1
  end
  h
end

def __arr_rindex(a, x)
  i = a.length - 1
  while i >= 0
    return i if a[i] == x
    i = i - 1
  end
  nil
end

def __arr_empty_check(a) = a.length == 0

def __hash_keys(h)
  out = []
  i = 0
  while i < __hcount(h)
    out.push(__hkey_at(h, i))
    i = i + 1
  end
  out
end

def __hash_merge(a, b)
  out = {}
  i = 0
  while i < __hcount(a)
    out[__hkey_at(a, i)] = __hval_at(a, i)
    i = i + 1
  end
  i = 0
  while i < __hcount(b)
    out[__hkey_at(b, i)] = __hval_at(b, i)
    i = i + 1
  end
  out
end

def __hash_to_a(h)
  out = []
  i = 0
  while i < __hcount(h)
    out.push([__hkey_at(h, i), __hval_at(h, i)])
    i = i + 1
  end
  out
end

def __hash_invert(h)
  out = {}
  i = 0
  while i < __hcount(h)
    out[__hval_at(h, i)] = __hkey_at(h, i)
    i = i + 1
  end
  out
end

def __hash_count(h) = __hcount(h)
def __hash_size(h) = __hcount(h)
def __hash_length(h) = __hcount(h)

def __hash_dig1(h, k) = h[k]

def __hash_any_p(h) = __hcount(h) > 0

def __hash_sum_values(h)
  t = 0
  i = 0
  while i < __hcount(h)
    t = t + __hval_at(h, i)
    i = i + 1
  end
  t
end

def __hash_min_by0(h)
  best = 0
  i = 1
  while i < __hcount(h)
    best = i if __hval_at(h, i) < __hval_at(h, best)
    i = i + 1
  end
  [__hkey_at(h, best), __hval_at(h, best)]
end

def __hash_max_by0(h)
  best = 0
  i = 1
  while i < __hcount(h)
    best = i if __hval_at(h, i) > __hval_at(h, best)
    i = i + 1
  end
  [__hkey_at(h, best), __hval_at(h, best)]
end

def __str_each_line(s)
  __fd_lines_of(s)
end

def __fd_lines_of(s)
  out = []
  start = 0
  i = 0
  while i < s.length
    if __ld8(s, i) == 10
      out.push(s[start, i + 1 - start])
      start = i + 1
    end
    i = i + 1
  end
  out.push(s[start, s.length - start]) if start < s.length
  out
end

def __str_lines(s)
  __fd_lines_of(s)
end

def __str_squeeze(s)
  out = ""
  i = 0
  while i < s.length
    out = out + s[i, 1] unless i > 0 && __ld8(s, i) == __ld8(s, i - 1)
    i = i + 1
  end
  out
end

def __str_delete(s, chars)
  out = ""
  i = 0
  while i < s.length
    out = out + s[i, 1] unless __str_include_p(chars, s[i, 1])
    i = i + 1
  end
  out
end

def __str_swapcase(s)
  out = __sdup(s)
  i = 0
  while i < out.length
    c = __ld8(out, i)
    __st8(out, i, c - 32) if c >= 97 && c <= 122
    __st8(out, i, c + 32) if c >= 65 && c <= 90
    i = i + 1
  end
  out
end

def __str_ord(s) = __ld8(s, 0)

def __str_empty_p(s) = s.length == 0

def __str_chop(s) = s.length > 0 ? s[0, s.length - 1] : ""

def __str_chomp(s)
  return s[0, s.length - 2] if s.length >= 2 && __ld8(s, s.length - 1) == 10 && __ld8(s, s.length - 2) == 13
  return s[0, s.length - 1] if s.length >= 1 && __ld8(s, s.length - 1) == 10
  __sdup(s)
end

def __str_to_f(s)
  i = 0
  neg = false
  if i < s.length && __ld8(s, i) == 45
    neg = true
    i = i + 1
  end
  v = 0.0
  while i < s.length && __ld8(s, i) >= 48 && __ld8(s, i) <= 57
    v = v * 10.0 + (__ld8(s, i) - 48)
    i = i + 1
  end
  if i < s.length && __ld8(s, i) == 46
    i = i + 1
    scale = 0.1
    while i < s.length && __ld8(s, i) >= 48 && __ld8(s, i) <= 57
      v = v + (__ld8(s, i) - 48) * scale
      scale = scale / 10.0
      i = i + 1
    end
  end
  neg ? 0.0 - v : v
end

def __str_hex(s)
  v = 0
  i = 0
  while i < s.length
    c = __ld8(s, i)
    d = c >= 48 && c <= 57 ? c - 48 : (c >= 97 && c <= 102 ? c - 87 : (c >= 65 && c <= 70 ? c - 55 : -1))
    return v if d < 0
    v = v * 16 + d
    i = i + 1
  end
  v
end

def __str_slice(s, start, len) = __str_byteslice(s, start, len)

def __str_prepend(s, t) = t + s

def __str_insert(s, i, t)
  i = s.length + i + 1 if i < 0
  s[0, i] + t + s[i, s.length - i]
end

def __str_each_byte(s) = __str_bytes(s)

def __str_scan_char(s, ch)
  out = []
  i = 0
  while i < s.length
    out.push(s[i, 1]) if __ld8(s, i) == __ld8(ch, 0)
    i = i + 1
  end
  out
end

def __str_partition(s, sep)
  at = __str_index_from(s, sep, 0)
  return [__sdup(s), "", ""] if at < 0
  [s[0, at], __sdup(sep), s[at + sep.length, s.length - at - sep.length]]
end

def __str_casecmp_p(a, b) = __str_downcase(a) == __str_downcase(b)

def __str_unpack_nothing(s) = s

def __num_times_arr(n)
  out = []
  i = 0
  while i < n
    out.push(i)
    i = i + 1
  end
  out
end

def __num_clamp(v, lo, hi)
  return lo if v < lo
  return hi if v > hi
  v
end

def __num_pow_mod(b, e, m)
  r = 1
  b = b % m
  while e > 0
    r = (r * b) % m if e % 2 == 1
    b = (b * b) % m
    e = e / 2
  end
  r
end

def __num_gcd(a, b)
  a = 0 - a if a < 0
  b = 0 - b if b < 0
  while b != 0
    t = a % b
    a = b
    b = t
  end
  a
end

def __num_lcm(a, b) = a == 0 || b == 0 ? 0 : __num_abs(a * b) / __num_gcd(a, b)

def __num_digits(n)
  out = []
  n = 0 - n if n < 0
  if n == 0
    out.push(0)
  end
  while n > 0
    out.push(n % 10)
    n = n / 10
  end
  out
end

def __num_bit_length(n)
  n = 0 - n - 1 if n < 0
  k = 0
  while n > 0
    n = n / 2
    k = k + 1
  end
  k
end

def __num_divmod(a, b) = [a / b, a % b]

def __num_fdiv(a, b) = a.to_f / b.to_f

def __num_between_p(v, lo, hi) = v >= lo && v <= hi

def __num_positive_p(v) = v > 0
def __num_negative_p(v) = v < 0

def __num_pred(n) = n - 1
def __num_succ(n) = n + 1

def __num_ceil(f) = (f.to_i.to_f == f ? f.to_i : (f > 0.0 ? f.to_i + 1 : f.to_i))
def __num_floor(f) = (f.to_i.to_f == f ? f.to_i : (f > 0.0 ? f.to_i : f.to_i - 1))
def __num_truncate(f) = f.to_i
def __num_nan_p(f) = f != f
def __num_infinite_p(f) = (f > 1.0e308 || f < -1.0e308) ? (f > 0.0 ? 1 : -1) : nil
def __num_finite_p(f) = !(f > 1.0e308 || f < -1.0e308) && f == f

def __hash_inspect(h)
  out = "{"
  i = 0
  while i < __hcount(h)
    out = out + ", " if i > 0
    out = out + __hkey_at(h, i).inspect + " => " + __hval_at(h, i).inspect
    i = i + 1
  end
  out + "}"
end

# symbol keys print as `name: value`
def __hash_inspect_sym(h)
  out = "{"
  i = 0
  while i < __hcount(h)
    out = out + ", " if i > 0
    out = out + __sym_name(__hkey_at(h, i)) + ": " + __hval_at(h, i).inspect
    i = i + 1
  end
  out + "}"
end

# tagged keys: a symbol prints as `name:`, anything else as inspect =>
def __hash_inspect_dyn(h)
  out = "{"
  i = 0
  while i < __hcount(h)
    out = out + ", " if i > 0
    k = __hkey_at(h, i)
    out = out + (__dyn_sym_p(k) ? __dyn_to_s(k) + ": " : __dyn_inspect(k) + " => ") + __hval_at(h, i).inspect
    i = i + 1
  end
  out + "}"
end

def __arr_slice(a, start, len)
  start = a.length + start if start < 0
  out = []
  i = start
  while i < start + len && i < a.length
    out.push(a[i])
    i = i + 1
  end
  out
end

# puts of an array: each element on its own line (nested arrays flattened, nil as an empty line)
def __arr_lines(a)
  out = ""
  i = 0
  while i < a.length
    out = out + a[i].to_s + "\n"
    i = i + 1
  end
  out.length > 0 ? out[0, out.length - 1] : out
end

# s[a..b] / a[a..b]: negative indices count from the end; hi -1 with excl 0 means "to the end"
def __str_slice_range(s, lo, hi, excl)
  n = s.length
  lo = lo + n if lo < 0
  hi = hi + n if hi < 0
  hi = hi - 1 if excl == 1
  return "" if lo > n || lo < 0
  hi = n - 1 if hi >= n
  len = hi - lo + 1
  len = 0 if len < 0
  s[lo, len]
end

def __arr_slice_range(a, lo, hi, excl)
  n = a.length
  lo = lo + n if lo < 0
  hi = hi + n if hi < 0
  hi = hi - 1 if excl == 1
  return [] if lo > n || lo < 0
  hi = n - 1 if hi >= n
  len = hi - lo + 1
  len = 0 if len < 0
  __arr_slice(a, lo, len)
end

# Array <=>: lexicographic, elementwise
def __arr_cmp(a, b)
  i = 0
  while i < a.length && i < b.length
    return -1 if a[i] < b[i]
    return 1 if a[i] > b[i]
    i = i + 1
  end
  return -1 if a.length < b.length
  return 1 if a.length > b.length
  0
end

def __arr_each_with_index_pairs(a)
  out = []
  i = 0
  while i < a.length
    out.push([a[i], i])
    i = i + 1
  end
  out
end

def __arr_join0(a) = __arr_join(a, "")

# a's contents become b's; a keeps its identity (the bang methods)
def __arr_replace(a, b)
  a.pop while a.length > b.length
  i = 0
  while i < b.length
    if i < a.length then a[i] = b[i] else a.push(b[i]) end
    i = i + 1
  end
  a
end

# a takes b's pairs; the same a comes back
def __hash_merge_into(a, b)
  i = 0
  while i < __hcount(b)
    a[__hkey_at(b, i)] = __hval_at(b, i)
    i = i + 1
  end
  a
end

# Integer#to_s(base), 2..36
def __num_to_s1(n, base)
  return "0" if n == 0
  neg = n < 0
  n = 0 - n if neg
  digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  out = ""
  while n > 0
    out = digits[n % base] + out
    n = n / base
  end
  neg ? "-" + out : out
end
