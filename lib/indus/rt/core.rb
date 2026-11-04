# Core routines written in the Indus subset and compiled into every program.
# Testable with plain Ruby: `ruby -r ./lib/indus/rt/core.rb`.


# Float#to_s: the shortest decimal that parses back to the same double.
# Tries 1..17 significant digits; digits come from scaling by a power of ten
# and truncating. Ruby's format: fixed for 1e-4 <= |f| < 1e16, else d.ddde+XX.
# 10.0**k. Exact for 0 <= k <= 22; beyond that by squaring, which is within a
# few ulps -- enough for the round-trip test except at extreme exponents
# (a known limit of this approach without big-integer arithmetic).
def __pow10(k)
  if k < 0
    return 1.0 / __pow10(0 - k)
  end
  r = 1.0
  b = 10.0
  while k > 0
    if k % 2 == 1
      r = r * b
    end
    b = b * b
    k = k / 2
  end
  r
end

# round to nearest integer, correct above 2**52 where adding 0.5 would not be
def __round_f(q)
  n = q.to_i
  if q - n.to_f >= 0.5
    n = n + 1
  end
  n
end

# decimal exponent e such that 10**e <= |f| < 10**(e+1)
def __dec_exp(f)
  e = 0
  if f >= 1.0
    while f >= 10.0
      f = f / 10.0
      e = e + 1
    end
  else
    while f < 1.0
      f = f * 10.0
      e = e - 1
    end
  end
  e
end

def __float_to_s(f)
  if f != f
    return "NaN"
  end
  if f == 0.0
    return "0.0"
  end
  neg = f < 0.0
  a = neg ? 0.0 - f : f
  if a > 1.7976931348623157e308
    return neg ? "-Infinity" : "Infinity"
  end
  digits = __grisu(a)
  kexp = __grisu_k
  ds = digits.to_s
  # strip trailing zeros from the significand; e is the decimal exponent of
  # the first digit: value = 0.ds * 10**(e+1) with digits * 10**kexp
  while ds.length > 1 && ds[ds.length - 1] == "0"
    ds = ds[0, ds.length - 1]
    kexp = kexp + 1
  end
  e = digits.to_s.length + kexp - 1
  out = ""
  # Ruby: fixed notation for decpt (= e+1) in -3..15, and at decpt 16 only when
  # fractional digits remain (2660891052749272.5 is fixed, 1.0e+15 is not)
  if e >= -4 && (e < 15 || (e == 15 && ds.length > 16))
    if e >= 0
      if ds.length > e + 1
        out = ds[0, e + 1] + "." + ds[e + 1, ds.length - e - 1]
      else
        out = ds
        z = e + 1 - ds.length
        while z > 0
          out = out + "0"
          z = z - 1
        end
        out = out + ".0"
      end
    else
      out = "0."
      z = 0 - e - 1
      while z > 0
        out = out + "0"
        z = z - 1
      end
      out = out + ds
    end
  else
    out = ds[0, 1] + "." + (ds.length > 1 ? ds[1, ds.length - 1] : "0") + "e" + (e < 0 ? "-" : "+")
    ae = e < 0 ? 0 - e : e
    out = out + (ae < 10 ? "0" : "") + ae.to_s
  end
  neg ? "-" + out : out
end

def __quote(s)
  "\"" + s + "\""
end

# Tagged scalars (:dyn): to_s / inspect by tag. Tags: 0 nil, odd fixnum,
# 2 String, 4 Array, 6 Hash, 8 object, 10 bool, 12 symbol, 14 Float box.
def __dyn_to_s(v)
  t = __tag(v)
  if __same(v, 0)
    return ""
  end
  if t & 1 == 1
    return __unbox_int(v).to_s
  end
  if t == 2
    return __unbox_str(v)
  end
  if t == 14
    return __float_to_s(__unbox_float(v))
  end
  if t == 10
    return __unbox_bool(v) ? "true" : "false"
  end
  if t == 4
    return __dyn_arr_inspect(__unbox_arr(v))
  end
  "#<object>"
end

def __dyn_inspect(v)
  t = __tag(v)
  if __same(v, 0)
    return "nil"
  end
  if t == 2
    return __quote(__unbox_str(v))
  end
  __dyn_to_s(v)
end

def __dyn_arr_inspect(a)
  out = "["
  i = 0
  while i < a.length
    out = out + ", " if i > 0
    out = out + __dyn_inspect(a[i])
    i = i + 1
  end
  out + "]"
end

# Operators on tagged scalars. Integer/Integer and Float mixes, String +.
# Anything else traps: a wrong answer is worse than a refusal.
def __dyn_num(v)
  t = __tag(v)
  if t & 1 == 1
    return __unbox_int(v).to_f
  end
  if t == 14
    return __unbox_float(v)
  end
  __trap
  0.0
end

def __dyn_both_int(a, b)
  (__tag(a) & 1 == 1) && (__tag(b) & 1 == 1)
end

def __dyn_add(a, b)
  if __dyn_both_int(a, b)
    return __box_int(__unbox_int(a) + __unbox_int(b))
  end
  if __tag(a) == 2 && __tag(b) == 2
    return __box_str(__unbox_str(a) + __unbox_str(b))
  end
  __box_float(__dyn_num(a) + __dyn_num(b))
end

def __dyn_sub(a, b)
  if __dyn_both_int(a, b)
    return __box_int(__unbox_int(a) - __unbox_int(b))
  end
  __box_float(__dyn_num(a) - __dyn_num(b))
end

def __dyn_mul(a, b)
  if __dyn_both_int(a, b)
    return __box_int(__unbox_int(a) * __unbox_int(b))
  end
  __box_float(__dyn_num(a) * __dyn_num(b))
end

def __dyn_div(a, b)
  if __dyn_both_int(a, b)
    return __box_int(__unbox_int(a) / __unbox_int(b))
  end
  __box_float(__dyn_num(a) / __dyn_num(b))
end

def __dyn_eq(a, b)
  if __tag(a) == 2 && __tag(b) == 2
    return __unbox_str(a) == __unbox_str(b)
  end
  if __dyn_both_int(a, b)
    return __same(a, b)
  end
  if __dyn_numeric(a) && __dyn_numeric(b)
    return __dyn_num(a) == __dyn_num(b)
  end
  __same(a, b)
end

def __dyn_numeric(v)
  (__tag(v) & 1 == 1) || __tag(v) == 14
end

def __dyn_ne(a, b)
  !__dyn_eq(a, b)
end

def __dyn_lt(a, b)
  if __dyn_both_int(a, b)
    return __unbox_int(a) < __unbox_int(b)
  end
  __dyn_num(a) < __dyn_num(b)
end

def __dyn_le(a, b)
  if __dyn_both_int(a, b)
    return __unbox_int(a) <= __unbox_int(b)
  end
  __dyn_num(a) <= __dyn_num(b)
end

def __dyn_gt(a, b)
  __dyn_lt(b, a)
end

def __dyn_ge(a, b)
  __dyn_le(b, a)
end

# String methods, in Ruby over the byte primitives __ld8 / __st8 / __sdup.
def __str_getbyte(s, i)
  __trap if i < 0 || i >= s.length
  __ld8(s, i)
end

def __str_setbyte(s, i, v)
  __trap if i < 0 || i >= s.length
  __st8(s, i, v)
  v
end

def __str_dup(s)
  __sdup(s)
end

def __str_b(s)
  __sdup(s)
end

def __str_bytes(s)
  out = []
  i = 0
  while i < s.length
    out.push(__ld8(s, i))
    i = i + 1
  end
  out
end

def __str_match_at(s, pat, at)
  j = 0
  while j < pat.length
    return false if __ld8(s, at + j) != __ld8(pat, j)
    j = j + 1
  end
  true
end

def __str_index_from(s, pat, from)
  i = from
  last = s.length - pat.length
  while i <= last
    return i if __str_match_at(s, pat, i)
    i = i + 1
  end
  -1
end

def __str_include_p(s, pat)
  __str_index_from(s, pat, 0) >= 0
end

def __str_start_with_p(s, pat)
  return false if pat.length > s.length
  __str_match_at(s, pat, 0)
end

def __str_end_with_p(s, pat)
  return false if pat.length > s.length
  __str_match_at(s, pat, s.length - pat.length)
end

def __str_index(s, pat, from = 0)
  r = __str_index_from(s, pat, from)
  return nil if r < 0
  r
end

def __str_strip(s)
  a = 0
  b = s.length
  a = a + 1 while a < b && __str_space(__ld8(s, a))
  b = b - 1 while b > a && __str_space(__ld8(s, b - 1))
  s[a, b - a]
end

def __str_lstrip(s)
  a = 0
  a = a + 1 while a < s.length && __str_space(__ld8(s, a))
  s[a, s.length - a]
end

def __str_rstrip(s)
  b = s.length
  b = b - 1 while b > 0 && __str_space(__ld8(s, b - 1))
  s[0, b]
end

# split(","): fields between separators; trailing empty fields dropped like Ruby.
# split(" ") is awk-style: runs of whitespace, leading/trailing ignored.
def __str_split(s, sep)
  out = []
  if sep == " "
    i = 0
    while i < s.length
      while i < s.length && __str_space(__ld8(s, i))
        i = i + 1
      end
      start = i
      while i < s.length && !__str_space(__ld8(s, i))
        i = i + 1
      end
      out.push(s[start, i - start]) if i > start
    end
    return out
  end
  start = 0
  i = 0
  while i <= s.length - sep.length
    if __str_match_at(s, sep, i)
      out.push(s[start, i - start])
      i = i + sep.length
      start = i
    else
      i = i + 1
    end
  end
  out.push(s[start, s.length - start])
  while out.length > 0 && out[out.length - 1].length == 0
    out.pop
  end
  out
end

def __str_space(c)
  c == 32 || c == 9 || c == 10 || c == 13
end

def __str_gsub(s, pat, rep)
  out = ""
  i = 0
  start = 0
  while i <= s.length - pat.length
    if __str_match_at(s, pat, i)
      out = out + s[start, i - start] + rep
      i = i + pat.length
      start = i
    else
      i = i + 1
    end
  end
  out + s[start, s.length - start]
end

def __str_succ(s)
  r = __sdup(s)
  i = r.length - 1
  while i >= 0
    c = __ld8(r, i)
    if c == 122
      __st8(r, i, 97)
    elsif c == 90
      __st8(r, i, 65)
    elsif c == 57
      __st8(r, i, 48)
    else
      __st8(r, i, c + 1)
      return r
    end
    i = i - 1
  end
  # carried past the front: prepend the right first character
  c = __ld8(r, 0)
  if c == 97
    "a" + r
  elsif c == 65
    "A" + r
  else
    "1" + r
  end
end

def __str_times(s, n)
  __trap if n < 0
  len = s.length
  out = __salloc(len * n)
  i = 0
  while i < n
    j = 0
    while j < len
      __st8(out, i * len + j, __ld8(s, j))
      j = j + 1
    end
    i = i + 1
  end
  out
end

# a tagged value where Ruby requires a String (`str << v`): unbox or trap (TypeError)
def __dyn_str(v)
  __trap if __tag(v) != 2
  __unbox_str(v)
end

# Array methods in Ruby, routed by Types.bind for a receiver typed [:arr, T]
def __arr_shift(a)
  __trap if a.length == 0
  first = a[0]
  i = 1
  while i < a.length
    a[i - 1] = a[i]
    i = i + 1
  end
  a.pop
  first
end

def __arr_reverse!(a)
  i = 0
  j = a.length - 1
  while i < j
    t = a[i]
    a[i] = a[j]
    a[j] = t
    i = i + 1
    j = j - 1
  end
  a
end

def __arr_empty_p(a)
  a.length == 0
end

def __arr_dup(a)
  out = []
  i = 0
  while i < a.length
    out.push(a[i])
    i = i + 1
  end
  out
end

def __arr_eq(a, b)
  return false if a.length != b.length
  i = 0
  while i < a.length
    return false if a[i] != b[i]
    i = i + 1
  end
  true
end

def __arr_inspect(a)
  out = "["
  i = 0
  while i < a.length
    out = out + ", " if i > 0
    out = out + a[i].inspect
    i = i + 1
  end
  out + "]"
end

# sort_by: a stable merge sort of the indices by key (keys computed once by the caller)
def __arr_sort_by(a, keys)
  n = a.length
  idx = Array.new(n, 0)
  tmp = Array.new(n, 0)
  i = 0
  while i < n
    idx[i] = i
    i = i + 1
  end
  width = 1
  while width < n
    lo = 0
    while lo < n
      mid = lo + width
      hi = lo + width * 2
      mid = n if mid > n
      hi = n if hi > n
      __merge_by(idx, tmp, keys, lo, mid, hi)
      lo = hi
    end
    t = idx
    idx = tmp
    tmp = t
    width = width * 2
  end
  out = Array.new(n, a[0])
  i = 0
  while i < n
    out[i] = a[idx[i]]
    i = i + 1
  end
  out
end

def __merge_by(idx, tmp, keys, lo, mid, hi)
  i = lo
  j = mid
  k = lo
  while k < hi
    if i < mid && (j >= hi || keys[idx[i]] <= keys[idx[j]])
      tmp[k] = idx[i]
      i = i + 1
    else
      tmp[k] = idx[j]
      j = j + 1
    end
    k = k + 1
  end
end

def __arr_min_by(a, keys)
  best = 0
  i = 1
  while i < a.length
    best = i if keys[i] < keys[best]
    i = i + 1
  end
  a[best]
end

def __arr_max_by(a, keys)
  best = 0
  i = 1
  while i < a.length
    best = i if keys[i] > keys[best]
    i = i + 1
  end
  a[best]
end

def __arr_sort(a)
  __arr_sort_by(a, a)
end

def __arr_min(a)
  __arr_min_by(a, a)
end

def __arr_max(a)
  __arr_max_by(a, a)
end

def __float_round(f, digits)
  m = 1.0
  i = 0
  while i < digits
    m = m * 10.0
    i = i + 1
  end
  x = f * m
  r = x >= 0.0 ? (x + 0.5).to_i : 0 - (0.0 - x + 0.5).to_i
  r.to_f / m
end

def __float_round0(f)
  f >= 0.0 ? (f + 0.5).to_i : 0 - (0.0 - f + 0.5).to_i
end
