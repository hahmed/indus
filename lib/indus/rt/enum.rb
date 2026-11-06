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
def __arr_count1(a, x)
  n = 0
  i = 0
  while i < a.length
    n = n + 1 if a[i] == x
    i = i + 1
  end
  n
end
def __arr_rotate1(a, k)
  out = []
  return out if a.length == 0
  k = k % a.length
  i = 0
  while i < a.length
    out.push(a[(i + k) % a.length])
    i = i + 1
  end
  out
end
def __str_slice1(s, i) = s[i]

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
def __str_chomp1(s, suffix) = __str_end_with_p(s, suffix) ? s[0, s.length - suffix.length] : __sdup(s)
def __str_chars_utf8(s) = __str_chars(s)

# "0.75".to_f: the digits as one integer mantissa, scaled once (digit-by-digit scaling
# accumulates error: 0.75 came out 0.7500000000000001). An exponent is applied by powers
# of ten, halving the number of roundings.
def __str_to_f(s)
  i = 0
  neg = false
  if i < s.length && (__ld8(s, i) == 45 || __ld8(s, i) == 43)
    neg = __ld8(s, i) == 45
    i = i + 1
  end
  mant = 0
  digits = 0
  over = 0
  dec = -1
  while i < s.length
    c = __ld8(s, i)
    if c >= 48 && c <= 57
      if mant <= 900719925474099 # room for one more digit inside 2^53 (a double's exact integers)
        mant = mant * 10 + (c - 48)
        digits = digits + 1
        dec = dec + 1 if dec >= 0 # a fractional digit that was taken: the point moves
      else
        over = over + 1 if dec < 0 # an integer digit past the mantissa: scale up instead (a dropped fractional digit changes nothing)
      end
      i = i + 1
    elsif c == 46 && dec < 0
      dec = 0
      i = i + 1
    else
      break
    end
  end
  exp = 0
  if i < s.length && (__ld8(s, i) == 101 || __ld8(s, i) == 69)
    i = i + 1
    eneg = false
    if i < s.length && (__ld8(s, i) == 45 || __ld8(s, i) == 43)
      eneg = __ld8(s, i) == 45
      i = i + 1
    end
    e = 0
    while i < s.length && __ld8(s, i) >= 48 && __ld8(s, i) <= 57
      e = e * 10 + (__ld8(s, i) - 48)
      i = i + 1
    end
    exp = eneg ? 0 - e : e
  end
  exp = exp - dec if dec > 0
  exp = exp + over
  v = mant.to_f
  # one rounding when the power of ten is exact in a double (10^0..10^22, strtod's fast path)
  if exp >= 0 && exp <= 22
    v = v * __pow10f(exp)
  elsif exp < 0 && exp >= -22
    v = v / __pow10f(0 - exp)
  elsif exp > 0
    k = 0
    while k < exp
      v = v * 10.0
      k = k + 1
    end
  else
    k = 0
    while k < 0 - exp
      v = v / 10.0
      k = k + 1
    end
  end
  neg ? 0.0 - v : v
end

# 10^k as a double for k in 0..22 (every one exact): built by repeated multiplication from
# 1.0, which is exact in this range, so no table lands in the program's frame
def __pow10f(k)
  v = 1.0
  i = 0
  while i < k
    v = v * 10.0
    i = i + 1
  end
  v
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
  head = i > 0 ? s[0, i] : ""
  tail = i < s.length ? s[i, s.length - i] : ""
  head + t + tail
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
  return __nil_str_value if lo > n || lo < 0 # s[7..] on a 5-char string is nil; s[5..] is ""
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
  __trap if b.length > a.length # growth through a parameter is not visible to the caller (no in-place growth yet)
  a.pop while a.length > b.length
  i = 0
  while i < b.length
    a[i] = b[i]
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

# [[k, v], ...] back into a hash (what a hash's select/reject/to_h yield)
def __pairs_to_hash(pairs)
  h = {}
  i = 0
  while i < pairs.length
    h[pairs[i][0]] = pairs[i][1]
    i = i + 1
  end
  h
end

# keys and values, parallel arrays, as a hash (transform_keys / transform_values)
def __hash_rekey(keys, vals)
  h = {}
  i = 0
  while i < keys.length
    h[keys[i]] = vals[i]
    i = i + 1
  end
  h
end

# ---- breadth batch 3 ----------------------------------------------------------------

def __arr_transpose(a)
  return [] if a.length == 0
  w = a[0].length
  out = []
  j = 0
  while j < w
    row = []
    i = 0
    while i < a.length
      __trap if a[i].length != w # ragged rows: IndexError in Ruby
      row.push(a[i][j])
      i = i + 1
    end
    out.push(row)
    j = j + 1
  end
  out
end

# the first n of the cycle (an endless cycle has no array form)
def __arr_cycle_first(a, n)
  out = []
  return out if a.length == 0
  i = 0
  while i < n
    out.push(a[i % a.length])
    i = i + 1
  end
  out
end

# combinations by index counting (no recursion: arrays do not grow through parameters)
def __arr_combination(a, k)
  out = []
  return out if k > a.length || k < 0
  idx = []
  i = 0
  while i < k
    idx.push(i)
    i = i + 1
  end
  loop_on = true
  while loop_on
    row = []
    i = 0
    while i < k
      row.push(a[idx[i]])
      i = i + 1
    end
    out.push(row)
    # advance: the rightmost index that can still move
    j = k - 1
    j = j - 1 while j >= 0 && idx[j] == a.length - k + j
    if j < 0
      loop_on = false
    else
      idx[j] = idx[j] + 1
      t = j + 1
      while t < k
        idx[t] = idx[t - 1] + 1
        t = t + 1
      end
    end
  end
  out
end

# k-permutations: every combination, each in every order (Heap's algorithm, iterative)
def __arr_permutation(a, k)
  out = []
  combos = __arr_combination(a, k)
  c = 0
  while c < combos.length
    perms = __arr_all_orders(combos[c])
    i = 0
    while i < perms.length
      out.push(perms[i])
      i = i + 1
    end
    c = c + 1
  end
  __arr_sort_by(out, __arr_perm_keys(out, a)) # Ruby yields in index order of the first element, then the next...
end

def __arr_permutation0(a) = __arr_permutation(a, a.length)

# a sort key per permutation: positions of its elements in the source, as one integer
def __arr_perm_keys(perms, a)
  keys = []
  p = 0
  while p < perms.length
    key = 0
    i = 0
    while i < perms[p].length
      key = key * (a.length + 1) + __arr_index_of(a, perms[p][i])
      i = i + 1
    end
    keys.push(key)
    p = p + 1
  end
  keys
end

def __arr_index_of(a, v)
  i = 0
  while i < a.length
    return i if a[i] == v
    i = i + 1
  end
  -1
end

def __arr_all_orders(items)
  n = items.length
  out = [items.dup]
  c = []
  i = 0
  while i < n
    c.push(0)
    i = i + 1
  end
  cur = items.dup
  i = 0
  while i < n
    if c[i] < i
      if i % 2 == 0
        t = cur[0]; cur[0] = cur[i]; cur[i] = t
      else
        t = cur[c[i]]; cur[c[i]] = cur[i]; cur[i] = t
      end
      out.push(cur.dup)
      c[i] = c[i] + 1
      i = 0
    else
      c[i] = 0
      i = i + 1
    end
  end
  out
end

# lo.step(hi, by): the values, as an array
def __num_step_to(lo, hi, by)
  out = []
  v = lo
  if by > 0
    while v <= hi
      out.push(v)
      v = v + by
    end
  else
    while v >= hi
      out.push(v)
      v = v + by
    end
  end
  out
end

def __arr_values_at(a, idxs)
  out = []
  i = 0
  while i < idxs.length
    out.push(a[idxs[i]])
    i = i + 1
  end
  out
end

def __hash_values_at(h, keys)
  out = []
  i = 0
  while i < keys.length
    out.push(h[keys[i]])
    i = i + 1
  end
  out
end

# insert returns the grown array; the lowering rebinds the receiver local to it
def __arr_insert(a, at, v)
  at = a.length + at + 1 if at < 0
  out = []
  i = 0
  while i < at
    out.push(a[i])
    i = i + 1
  end
  out.push(v)
  while i < a.length
    out.push(a[i])
    i = i + 1
  end
  out
end

def __arr_delete_at(a, at)
  at = a.length + at if at < 0
  return nil if at < 0 || at >= a.length
  v = a[at]
  i = at
  while i < a.length - 1
    a[i] = a[i + 1]
    i = i + 1
  end
  a.pop
  v
end

def __arr_assoc(a, key)
  i = 0
  while i < a.length
    return a[i] if a[i][0] == key
    i = i + 1
  end
  nil
end

def __arr_reverse_each_pairs(a) = __arr_reverse(a) # reverse_each without a block: the reversed array

def __hash_value_p(h, v)
  i = 0
  while i < __hcount(h)
    return true if __hval_at(h, i) == v
    i = i + 1
  end
  false
end

def __hash_fetch2(h, k, default) = __hkey_p(h, k) ? h[k] : default

def __hash_sort(h)
  pairs = __hash_to_a(h)
  keys = __arr_map_first(pairs)
  if keys.length > 0 && __is_dyn(keys[0]) && __dyn_sym_p(keys[0]) # symbols order by name
    keys = __arr_sym_names(keys)
  end
  __arr_sort_by(pairs, keys)
end

def __arr_sym_names(a)
  out = []
  i = 0
  while i < a.length
    out.push(__dyn_to_s(a[i])) # pairs from a hash carry tagged keys
    i = i + 1
  end
  out
end

def __arr_map_first(pairs)
  out = []
  i = 0
  while i < pairs.length
    out.push(pairs[i][0])
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

# Open addressing has no cheap delete: keep every other pair, clear the table in place
# (the handle stays valid for everyone holding it), reinsert. Layout: [-16] cap, [-8] count,
# cap * 16 bytes of [key, val] slots, then cap words of insertion order.
def __hash_delete(h, k)
  return nil unless __hkey_p(h, k)
  v = h[k]
  pairs = __hash_to_a(h)
  base = __handle(h)
  cap = __ld(base - 16)
  i = 0
  while i < cap * 2
    __st(base + i * 8, 0)
    i = i + 1
  end
  __st(base - 8, 0)
  i = 0
  while i < pairs.length
    __hset_raw(h, pairs[i][0], pairs[i][1]) unless pairs[i][0] == k
    i = i + 1
  end
  v
end

def __str_rindex(s, pat)
  i = s.length - pat.length
  while i >= 0
    return i if s[i, pat.length] == pat
    i = i - 1
  end
  nil
end

# "az".succ == "ba": the rightmost alphanumeric run carries
def __str_succ(s)
  return "" if s.length == 0
  chars = s.chars
  i = chars.length - 1
  while i >= 0
    c = chars[i]
    if c == "z" then chars[i] = "a"
    elsif c == "Z" then chars[i] = "A"
    elsif c == "9" then chars[i] = "0"
    elsif (c >= "a" && c < "z") || (c >= "A" && c < "Z") || (c >= "0" && c < "9")
      chars[i] = (c.ord + 1).chr
      return chars.join("")
    else
      return chars.join("") # not alphanumeric: Ruby carries past it only when there is something alnum to the left; close enough here
    end
    i = i - 1
  end
  # carried off the left end: prepend
  first = s[0]
  lead = first == "z" || first == "Z" ? (first == "z" ? "a" : "A") : "1"
  lead + chars.join("")
end

# parse an integer in a base, stopping at the first bad digit (Ruby's lenient to_i)
def __str_to_i_base(s, base)
  i = 0
  neg = false
  if s.length > 0 && (s[0] == "-" || s[0] == "+")
    neg = s[0] == "-"
    i = 1
  end
  # 0x / 0b / 0o prefixes matching the base are allowed
  if s.length > i + 1 && s[i] == "0"
    p = s[i + 1]
    if (base == 16 && (p == "x" || p == "X")) || (base == 2 && (p == "b" || p == "B")) || (base == 8 && (p == "o" || p == "O"))
      i = i + 2
    end
  end
  n = 0
  while i < s.length
    c = s[i]
    d = -1
    d = c.ord - 48 if c >= "0" && c <= "9"
    d = c.ord - 87 if c >= "a" && c <= "z"
    d = c.ord - 55 if c >= "A" && c <= "Z"
    break if c == "_"
    break if d < 0 || d >= base
    n = n * base + d
    i = i + 1
  end
  neg ? 0 - n : n
end

def __str_hex(s) = __str_to_i_base(s, 16)
def __str_oct(s)
  # 0x/0b prefixes switch the base; otherwise octal
  return __str_to_i_base(s, 16) if s.length > 1 && s[0] == "0" && (s[1] == "x" || s[1] == "X")
  return __str_to_i_base(s, 2) if s.length > 1 && s[0] == "0" && (s[1] == "b" || s[1] == "B")
  __str_to_i_base(s, 8)
end

# Float#round(n) with a digit count; Integer#round(-n) to tens/hundreds
def __num_round_int(n, digits)
  return n if digits >= 0
  m = 1
  k = 0
  while k < 0 - digits
    m = m * 10
    k = k + 1
  end
  neg = n < 0
  n = 0 - n if neg
  q = n / m
  r = n - q * m
  q = q + 1 if r * 2 >= m # half away from zero, as Integer#round does
  neg ? 0 - q * m : q * m
end

def __arr_max_n(a, n)
  s = __arr_sort(a)
  out = []
  i = s.length - 1
  while i >= 0 && out.length < n
    out.push(s[i])
    i = i - 1
  end
  out
end

def __arr_min_n(a, n)
  s = __arr_sort(a)
  out = []
  i = 0
  while i < s.length && i < n
    out.push(s[i])
    i = i + 1
  end
  out
end

def __arr_sum_str(a, init)
  out = init
  i = 0
  while i < a.length
    out = out + a[i]
    i = i + 1
  end
  out
end

def __arr_sample(a) = a[__rand_int(a.length)]

def __arr_shuffle(a)
  out = a.dup
  i = out.length - 1
  while i > 0
    j = __rand_int(i + 1)
    t = out[i]
    out[i] = out[j]
    out[j] = t
    i = i - 1
  end
  out
end

# xorshift64*, seeded once per run
def __rand_int(n)
  x = $__rand_state
  x = x ^ (x << 13)
  x = x ^ __lsr(x, 7)
  x = x ^ (x << 17)
  $__rand_state = x
  r = __lsr(x, 1) % n
  r
end
$__rand_state = 88172645463325252

def __rand_float
  __lsr($__rand_state = ($__rand_state ^ ($__rand_state << 13)) ^ __lsr($__rand_state, 7), 11).to_f * (2.0 ** -53)
end

def __num_isqrt(n)
  return 0 if n <= 0
  x = n
  y = (x + 1) / 2
  while y < x
    x = y
    y = (x + n / x) / 2
  end
  x
end

def __num_digits(n)
  out = []
  n = 0 - n if n < 0
  return [0] if n == 0
  while n > 0
    out.push(n % 10)
    n = n / 10
  end
  out
end

def __num_bit_length(n)
  n = ~n if n < 0
  c = 0
  while n > 0
    n = n >> 1
    c = c + 1
  end
  c
end

# block methods as a map plus a pass over the mask of truths
def __arr_take_while_mask(a, mask)
  out = []
  i = 0
  while i < a.length && mask[i]
    out.push(a[i])
    i = i + 1
  end
  out
end

def __arr_drop_while_mask(a, mask)
  i = 0
  i = i + 1 while i < a.length && mask[i]
  __arr_slice(a, i, a.length - i)
end

def __arr_index_mask(a, mask)
  i = 0
  while i < mask.length
    return i if mask[i]
    i = i + 1
  end
  nil
end
def __arr_find_index_mask(a, mask) = __arr_index_mask(a, mask)

def __arr_one_mask(a, mask)
  c = 0
  i = 0
  while i < mask.length
    c = c + 1 if mask[i]
    i = i + 1
  end
  c == 1
end

# chunk_while: mask[i] says a[i] and a[i+1] belong together
def __arr_chunk_while_mask(a, mask)
  out = []
  return out if a.length == 0
  cur = [a[0]]
  i = 1
  while i < a.length
    if mask[i - 1]
      cur.push(a[i])
    else
      out.push(cur)
      cur = [a[i]]
    end
    i = i + 1
  end
  out.push(cur)
  out
end

# slice_when: mask[i] says a slice ends between a[i] and a[i+1]
def __arr_slice_when_mask(a, mask)
  out = []
  return out if a.length == 0
  cur = [a[0]]
  i = 1
  while i < a.length
    if mask[i - 1]
      out.push(cur)
      cur = [a[i]]
    else
      cur.push(a[i])
    end
    i = i + 1
  end
  out.push(cur)
  out
end

def __rand_range(lo, hi) = lo + __rand_int(hi - lo + 1)
def __str_next(s) = __str_succ(s)
def __str_to_i1(s, base) = __str_to_i_base(s, base)
def __num_step2(lo, hi, by) = __num_step_to(lo, hi, by)
def __arr_max1(a, n) = __arr_max_n(a, n)
def __arr_min1(a, n) = __arr_min_n(a, n)
def __arr_sum1(a, init) = __arr_sum_str(a, init)
def __arr_combination1(a, k) = __arr_combination(a, k)
def __arr_permutation1(a, k) = __arr_permutation(a, k)
def __arr_reverse_each(a) = __arr_reverse(a)
def __arr_to_h(pairs) = __pairs_to_hash(pairs)
def __arr_values_at1(a, i) = __arr_values_at(a, [i])
def __arr_insert2(a, at, v) = __arr_insert(a, at, v)
def __arr_delete_at1(a, at) = __arr_delete_at(a, at)
def __arr_assoc1(a, k) = __arr_assoc(a, k)
def __hash_value_p1(h, v) = __hash_value_p(h, v)
def __hash_values_at1(h, k) = __hash_values_at(h, [k])
def __hash_values_at2(h, a, b) = __hash_values_at(h, [a, b])
def __arr_values_at2(a, i, j) = __arr_values_at(a, [i, j])
def __str_rindex1(s, pat) = __str_rindex(s, pat)
def __hash_delete1(h, k) = __hash_delete(h, k)

# nested arrays flattened fully (elements of mixed depth are tagged values)
# flatten, chosen by element type (a runtime test here would type both arms: notes/52)
def __arr_flatten(a) # tagged elements: an element that is an array is spliced in
  out = []
  i = 0
  while i < a.length
    e = a[i]
    if __dyn_arr_p(e)
      inner = __arr_flatten(__dyn_arr(e))
      j = 0
      while j < inner.length
        out.push(inner[j])
        j = j + 1
      end
    else
      out.push(e)
    end
    i = i + 1
  end
  out
end

def __arr_flatten_nested(a) # array elements: splice each one in
  out = []
  i = 0
  while i < a.length
    e = a[i]
    j = 0
    while j < e.length
      out.push(e[j])
      j = j + 1
    end
    i = i + 1
  end
  out
end

# ---- Set: a hash of element => true ----------------------------------------------------
class Set
  def initialize(items = nil)
    @h = {}
    unless items.nil?
      i = 0
      while i < items.length
        @h[items[i]] = true
        i = i + 1
      end
    end
  end
  def add(x)
    @h[x] = true
    self
  end
  def <<(x) = add(x)
  def include?(x) = @h.key?(x)
  def member?(x) = @h.key?(x)
  def size = @h.size
  def length = @h.size
  def empty? = @h.size == 0
  def delete(x)
    @h.delete(x)
    self
  end
  def to_a = @h.keys
  def each(&blk) = @h.keys.each(&blk)
  def add?(x)
    return nil if @h.key?(x)
    @h[x] = true
    self
  end
end

# sort with a comparator (a block value): merge sort calling cmp.call(a, b)
def __arr_sort_cmp(a, cmp)
  return a.dup if a.length < 2
  mid = a.length / 2
  left = __arr_sort_cmp(__arr_slice(a, 0, mid), cmp)
  right = __arr_sort_cmp(__arr_slice(a, mid, a.length - mid), cmp)
  out = []
  i = 0
  j = 0
  while i < left.length && j < right.length
    if cmp.call(left[i], right[j]) <= 0
      out.push(left[i])
      i = i + 1
    else
      out.push(right[j])
      j = j + 1
    end
  end
  while i < left.length
    out.push(left[i])
    i = i + 1
  end
  while j < right.length
    out.push(right[j])
    j = j + 1
  end
  out
end

def __hash_dup(h)
  out = {}
  i = 0
  while i < __hcount(h)
    out[__hkey_at(h, i)] = __hval_at(h, i)
    i = i + 1
  end
  out
end

# ("a".."e"): each successor until past the end (or the lengths diverge, as Ruby stops)
def __str_range(lo, hi, excl)
  out = []
  cur = lo
  while cur.length <= hi.length
    break if excl == 1 && cur == hi
    out.push(cur)
    break if cur == hi
    cur = __str_succ(cur)
  end
  out
end
def __arr_to_a(a) = a

# a typed container as a tagged one: a copy whose elements are tagged. The parameter keeps
# its own element type; `out` is a tagged container, so each store boxes.
def __box_elems_arr(a)
  out = []
  i = 0
  while i < a.length
    out.push(__to_dyn(a[i]))
    i = i + 1
  end
  out
end

def __box_elems_hash(h)
  out = {}
  i = 0
  while i < __hcount(h)
    out[__to_dyn(__hkey_at(h, i))] = __to_dyn(__hval_at(h, i))
    i = i + 1
  end
  out
end

# ---- probe batch (2026-11-07): hash and string odds and ends
def __hash_has_value_p(h, v) = __hash_value_p(h, v)
def __hash_key(h, v)
  keys = __hash_keys(h)
  i = 0
  while i < keys.length
    return keys[i] if h[keys[i]] == v
    i = i + 1
  end
  nil
end
def __hash_first(h)
  return nil if __hcount(h) == 0
  [__hkey_at(h, 0), __hval_at(h, 0)]
end
def __hash_first1(h, n)
  out = []
  i = 0
  while i < n && i < __hcount(h)
    out.push([__hkey_at(h, i), __hval_at(h, i)])
    i = i + 1
  end
  out
end
def __hash_slice(h, keys)
  out = {}
  i = 0
  while i < keys.length
    out[keys[i]] = h[keys[i]] if __hkey_p(h, keys[i])
    i = i + 1
  end
  out
end
def __hash_slice1(h, a) = __hash_slice(h, [a])
def __hash_slice2(h, a, b) = __hash_slice(h, [a, b])
def __hash_slice3(h, a, b, c) = __hash_slice(h, [a, b, c])
def __hash_except(h, keys)
  out = {}
  i = 0
  while i < __hcount(h)
    k = __hkey_at(h, i)
    out[k] = __hval_at(h, i) unless __arr_include_p(keys, k)
    i = i + 1
  end
  out
end
def __hash_except1(h, a) = __hash_except(h, [a])
def __hash_except2(h, a, b) = __hash_except(h, [a, b])
def __hash_store(h, k, v) = (h[k] = v)
def __hash_flatten(h)
  out = []
  i = 0
  while i < __hcount(h)
    out.push(__hkey_at(h, i))
    out.push(__hval_at(h, i))
    i = i + 1
  end
  out
end
def __hash_each_key(h) = __hash_keys(h)
def __hash_each_value(h) = __hash_values(h)
def __hash_each_pair(h) = __hash_to_a(h)
def __hash_each(h) = __hash_to_a(h)

def __str_rpartition(s, sep)
  at = __str_rindex(s, sep)
  return ["", "", __sdup(s)] if at < 0
  [s[0, at], __sdup(sep), s[at + sep.length, s.length - at - sep.length]]
end
def __str_eql_p(a, b) = a == b
def __str_equal_p(a, b) = __same(a, b)
def __str_between_p(s, lo, hi) = __str_spaceship(s, lo) >= 0 && __str_spaceship(s, hi) <= 0
def __str_casecmp(a, b) = __str_spaceship(__str_downcase(a), __str_downcase(b))
def __str_delete_prefix(s, p) = __str_start_with_p(s, p) ? s[p.length, s.length - p.length] : __sdup(s)
def __str_delete_suffix(s, p) = __str_end_with_p(s, p) ? s[0, s.length - p.length] : __sdup(s)
def __str_start_with_p2(s, a, b) = __str_start_with_p(s, a) || __str_start_with_p(s, b)
def __str_start_with_p3(s, a, b, c) = __str_start_with_p(s, a) || __str_start_with_p(s, b) || __str_start_with_p(s, c)
def __str_end_with_p2(s, a, b) = __str_end_with_p(s, a) || __str_end_with_p(s, b)
def __str_hash(s)
  h = 5381
  i = 0
  while i < s.length
    h = __wadd(__wmul(h, 33), __ld8(s, i))
    i = i + 1
  end
  h & 4611686018427387903
end
def __str_each_char(s) = __str_chars(s)
def __arr_each_entry(a) = a
def __arr_each(a) = a
def __hash_merge_blk(a, b, blk)
  out = __hash_dup(a)
  i = 0
  while i < __hcount(b)
    k = __hkey_at(b, i)
    v = __hval_at(b, i)
    out[k] = __hkey_p(out, k) ? blk.call(k, out[k], v) : v
    i = i + 1
  end
  out
end
def __hash_fetch_blk(h, k, blk) = __hkey_p(h, k) ? h[k] : blk.call(k)
# rebuild h's slots from `from` (same key/value types): the in-place variants
def __hash_replace(h, from)
  pairs = __hash_to_a(from)
  base = __handle(h)
  cap = __ld(base - 16)
  i = 0
  while i < cap * 2
    __st(base + i * 8, 0)
    i = i + 1
  end
  __st(base - 8, 0)
  i = 0
  while i < pairs.length
    __hset_raw(h, pairs[i][0], pairs[i][1])
    i = i + 1
  end
  h
end
def __hash_clear(h) = __hash_replace(h, {})
def __hash_compact(h)
  out = {}
  i = 0
  while i < __hcount(h)
    v = __hval_at(h, i)
    out[__hkey_at(h, i)] = v unless v.nil?
    i = i + 1
  end
  out
end
def __arr_each_with_index_pairs_from(a, from)
  out = []
  i = 0
  while i < a.length
    out.push([a[i], i + from])
    i = i + 1
  end
  out
end
def __num_upto_a(a, b)
  out = []
  while a <= b
    out.push(a)
    a = a + 1
  end
  out
end
def __num_downto_a(a, b)
  out = []
  while a >= b
    out.push(a)
    a = a - 1
  end
  out
end
def __str_squeeze1(s, set)
  out = ""
  i = 0
  while i < s.length
    c = __ld8(s, i)
    out = out + s[i, 1] unless i > 0 && c == __ld8(s, i - 1) && __str_include_p(set, s[i, 1])
    i = i + 1
  end
  out
end
def __num_remainder(a, b) = a - b * (a.abs / b.abs) * (a < 0 ? -1 : 1) * (b < 0 ? -1 : 1)
def __num_modulo(a, b) = a % b
def __num_digits1(n, base)
  out = []
  return [0] if n == 0
  while n > 0
    out.push(n % base)
    n = n / base
  end
  out
end
def __num_integer_p(n) = true
def __num_ord(n) = n
def __num_size(n) = 8
def __arr_sort_sym(a) = __arr_sort_by(a, __arr_sym_names(a))
def __arr_min_sym(a) = __arr_min_by(a, __arr_sym_names(a))
def __arr_max_sym(a) = __arr_max_by(a, __arr_sym_names(a))
def __arr_flatten1(a, depth) # tagged elements, one level per depth
  return __arr_dup(a) if depth == 0
  out = []
  i = 0
  while i < a.length
    e = a[i]
    if __dyn_arr_p(e)
      inner = __arr_flatten1(__dyn_arr(e), depth - 1)
      j = 0
      while j < inner.length
        out.push(inner[j])
        j = j + 1
      end
    else
      out.push(e)
    end
    i = i + 1
  end
  out
end
def __arr_zip2(a, b, c)
  out = []
  i = 0
  while i < a.length
    out.push([a[i], b[i], c[i]])
    i = i + 1
  end
  out
end
# tagged receivers with one argument: the tag decides between the array and string families
def __dyn_include_p(v, x)
  return __arr_include_p(__dyn_arr(v), x) if __tag(v) == 4
  return __str_include_p(__dyn_str(v), __dyn_str(x)) if __tag(v) == 2
  __hkey_p(__dyn_hash(v), x) if __tag(v) == 6
end
def __dyn_join(v, sep) = __arr_join(__dyn_arr(v), sep)
def __dyn_first1(v, n) = __arr_first1(__dyn_arr(v), n)
def __dyn_last1(v, n) = __arr_last1(__dyn_arr(v), n)
