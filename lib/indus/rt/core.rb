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

# String#inspect: quotes, with \n \t \" \\ escaped
def __quote(s)
  out = "\""
  i = 0
  while i < s.length
    c = __ld8(s, i)
    if c == 10 then out = out + "\\n"
    elsif c == 9 then out = out + "\\t"
    elsif c == 34 then out = out + "\\\""
    elsif c == 92 then out = out + "\\\\"
    else out = out + s[i, 1] end
    i = i + 1
  end
  out + "\""
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
  if t == 12
    return __sym_name(__unbox_sym(v))
  end
  "#<object>"
end

def __dyn_sym_p(v) = __tag(v) == 12

def __dyn_inspect(v)
  t = __tag(v)
  if __same(v, 0)
    return "nil"
  end
  if t == 2
    return __quote(__unbox_str(v))
  end
  if t == 12
    return ":" + __sym_name(__unbox_sym(v))
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

def __dyn_mod(a, b)
  if __dyn_both_int(a, b)
    return __box_int(__unbox_int(a) % __unbox_int(b))
  end
  __box_float(__dyn_num(a) % __dyn_num(b))
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
  if __tag(a) == 2 && __tag(b) == 2
    return __unbox_str(a) < __unbox_str(b)
  end
  __dyn_num(a) < __dyn_num(b)
end

def __dyn_le(a, b)
  if __dyn_both_int(a, b)
    return __unbox_int(a) <= __unbox_int(b)
  end
  if __tag(a) == 2 && __tag(b) == 2
    return __unbox_str(a) <= __unbox_str(b)
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

def __arr_reverse_bang(a)
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

# Files. A file is a descriptor (an Integer); File.open yields it and closes it after
# the block. Paths go to libc NUL-terminated.
def __cstr(s)
  s + "\0"
end

def __file_open(path, mode)
  fd = mode == "w" ? __sys_creat(__cstr(path), 420) : __sys_open(__cstr(path), 0)
  __trap if fd < 0
  fd
end

def __file_close(fd)
  __sys_close(fd)
  0
end

def __file_delete(path)
  __sys_unlink(__cstr(path))
end

def __fd_write(fd, s)
  __sys_write(fd, s, s.length)
end

def __fd_puts(fd, s)
  __sys_write(fd, s, s.length)
  __sys_write(fd, "\n", 1) unless s.length > 0 && __ld8(s, s.length - 1) == 10
  0
end

def __fd_close(fd)
  __sys_close(fd)
end

def __fd_read_all(fd)
  out = ""
  buf = __salloc(65536)
  n = __sys_read(fd, buf, 65536)
  while n > 0
    out = out + buf[0, n]
    n = __sys_read(fd, buf, 65536)
  end
  out
end

# each_line: lines keep their newline, like Ruby
def __fd_lines(fd)
  s = __fd_read_all(fd)
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

def __str_byteslice(s, start, len)
  return "" if start >= s.length
  len = s.length - start if start + len > s.length
  s[start, len]
end

# String#sum: the byte sum (mod 2**16 in Ruby's default; callers here reduce it further)
def __str_sum(s)
  t = 0
  i = 0
  while i < s.length
    t = t + __ld8(s, i)
    i = i + 1
  end
  t % 65536
end

def __dyn_length(v)
  t = __tag(v)
  return __unbox_str(v).length if t == 2
  return __unbox_arr(v).length if t == 4
  __trap
  0
end

# Exceptions. raise "m" is RuntimeError.new("m"); rescue matches by class.
# Object.new: an object with no state (a sentinel, a lock token). Singleton methods and
# extend on one instance are not supported: every object of a class shares its methods.
class Object
end

class StandardError
  attr_reader :message
  def initialize(message = "unhandled exception")
    @message = message
  end
end
class RuntimeError < StandardError
end
class ArgumentError < StandardError
end
class TypeError < StandardError
end
class ZeroDivisionError < StandardError
end
class IndexError < StandardError
end
class KeyError < IndexError
end
class NameError < StandardError
end
class RangeError < StandardError
end
class FloatDomainError < RangeError
end
class StopIteration < IndexError
end
class FrozenError < RuntimeError
end
class IOError < StandardError
end
class NotImplementedError < StandardError
end
class NoMethodError < NameError
end

# nothing rescued it: Ruby prints the message to stderr and exits 1
def __uncaught(e)
  $stderr.puts e.message
  __sys_exit(1)
  0
end

def __num_spaceship(a, b)
  return -1 if a < b
  return 1 if a > b
  0
end

def __str_spaceship(a, b)
  return -1 if a < b
  return 1 if a > b
  0
end

# Comparable: everything from <=>. Compiled into each class that includes it.
module Comparable
  def <(other) = (self <=> other) < 0
  def <=(other) = (self <=> other) <= 0
  def >(other) = (self <=> other) > 0
  def >=(other) = (self <=> other) >= 0
  def ==(other) = (self <=> other) == 0
  def between?(lo, hi) = self >= lo && self <= hi
end

def __num_even_p(n) = n % 2 == 0
def __num_odd_p(n) = n % 2 != 0
def __num_abs(n) = n < 0 ? 0 - n : n
def __num_zero_p(n) = n == 0

def __arr_sum(a)
  t = 0
  i = 0
  while i < a.length
    t = t + a[i]
    i = i + 1
  end
  t
end

def __arr_uniq(a)
  out = []
  i = 0
  while i < a.length
    j = 0
    seen = false
    while j < out.length
      seen = true if out[j] == a[i]
      j = j + 1
    end
    out.push(a[i]) unless seen
    i = i + 1
  end
  out
end

def __arr_include_p(a, x)
  i = 0
  while i < a.length
    return true if a[i] == x
    i = i + 1
  end
  false
end

def __arr_index(a, x)
  i = 0
  while i < a.length
    return i if a[i] == x
    i = i + 1
  end
  nil
end

def __arr_reverse(a)
  out = []
  i = a.length - 1
  while i >= 0
    out.push(a[i])
    i = i - 1
  end
  out
end

def __arr_first(a) = a[0]
def __arr_last(a) = a[a.length - 1]

def __arr_take(a, n)
  out = []
  i = 0
  while i < n && i < a.length
    out.push(a[i])
    i = i + 1
  end
  out
end

def __arr_join(a, sep)
  out = ""
  i = 0
  while i < a.length
    out = out + sep if i > 0
    e = a[i]
    if __is_dyn(e) && __dyn_arr_p(e) then out = out + __arr_join(__dyn_arr(e), sep) # nested arrays join recursively
    else out = out + e.to_s end
    i = i + 1
  end
  out
end

def __str_reverse(s)
  out = __salloc(s.length)
  i = 0
  while i < s.length
    __st8(out, i, __ld8(s, s.length - 1 - i))
    i = i + 1
  end
  out
end

def __str_upcase(s)
  out = __sdup(s)
  i = 0
  while i < out.length
    c = __ld8(out, i)
    __st8(out, i, c - 32) if c >= 97 && c <= 122
    i = i + 1
  end
  out
end

def __str_downcase(s)
  out = __sdup(s)
  i = 0
  while i < out.length
    c = __ld8(out, i)
    __st8(out, i, c + 32) if c >= 65 && c <= 90
    i = i + 1
  end
  out
end

def __str_capitalize(s)
  out = __str_downcase(s)
  if out.length > 0
    c = __ld8(out, 0)
    __st8(out, 0, c - 32) if c >= 97 && c <= 122
  end
  out
end

# tr with single characters or simple sets (no ranges yet)
def __str_tr(s, from, to)
  out = __sdup(s)
  i = 0
  while i < out.length
    j = 0
    while j < from.length
      if __ld8(out, i) == __ld8(from, j)
        __st8(out, i, __ld8(to, j < to.length ? j : to.length - 1))
        j = from.length
      end
      j = j + 1
    end
    i = i + 1
  end
  out
end

def __str_chars(s)
  out = []
  i = 0
  while i < s.length
    out.push(s[i, 1])
    i = i + 1
  end
  out
end

def __str_sub(s, pat, rep)
  at = __str_index_from(s, pat, 0)
  return __sdup(s) if at < 0
  s[0, at] + rep + s[at + pat.length, s.length - at - pat.length]
end

def __str_count(s, set)
  n = 0
  i = 0
  while i < s.length
    j = 0
    while j < set.length
      n = n + 1 if __ld8(s, i) == __ld8(set, j)
      j = j + 1
    end
    i = i + 1
  end
  n
end

def __str_ljust1(s, w) = __str_ljust(s, w, " ")
def __str_rjust1(s, w) = __str_rjust(s, w, " ")
def __str_center1(s, w) = __str_center(s, w, " ")

def __str_ljust(s, w, pad)
  out = __sdup(s)
  out = out + pad while out.length < w
  out
end

def __str_rjust(s, w, pad)
  out = __sdup(s)
  out = pad + out while out.length < w
  out
end

def __str_center(s, w, pad)
  out = __sdup(s)
  left = true
  while out.length < w
    out = left ? out + pad : pad + out
    left = !left
  end
  out
end

# Symbols are small integers at run time; SYMBOL_NAMES (built at the top of main) has their names
def __sym_name(id) = SYMBOL_NAMES[id]
def __sym_inspect(id) = ":" + SYMBOL_NAMES[id]

def __hash_values(h)
  out = []
  i = 0
  while i < __hcount(h)
    out.push(__hval_at(h, i))
    i = i + 1
  end
  out
end

def __hash_fetch(h, k)
  __trap unless __hkey_p(h, k) # KeyError
  h[k]
end

def __hash_key_p(h, k) = __hkey_p(h, k)
def __hash_has_key_p(h, k) = __hkey_p(h, k)
def __hash_include_p(h, k) = __hkey_p(h, k)
def __hash_empty_p(h) = __hcount(h) == 0

# unbox-or-trap for a tagged value used as one builtin kind
def __dyn_int(v)
  __trap if __tag(v) & 1 != 1
  __unbox_int(v)
end
def __dyn_arr(v)
  __trap if __tag(v) != 4
  __unbox_arr(v)
end

# a nullable integer (:int?) carries nil as the most negative word
def __opt_inspect(v)
  v == -9223372036854775808 ? "nil" : v.to_s
end
def __opt_to_s(v)
  v == -9223372036854775808 ? "" : v.to_s
end

def __class_name(id) = CLASS_NAMES[id]

def __raise_zero_div
  raise ZeroDivisionError, "divided by 0"
end

def __dyn_arr_p(v) = __tag(v) == 4

def __dyn_float(v)
  __trap if __tag(v) != 14
  __unbox_float(v)
end
def __dyn_hash(v)
  __trap if __tag(v) != 6
  __unbox_hash(v)
end

def __dyn_sym(v)
  __trap if __tag(v) != 12
  __unbox_sym(v)
end

# the class name of a tagged value, by tag; objects carry their class id in word 0
def __dyn_class_name(v)
  t = __tag(v)
  return "Integer" if t & 1 == 1
  return "NilClass" if v == 0
  return "String" if t == 2
  return "Array" if t == 4
  return "Hash" if t == 6
  return "Symbol" if t == 12
  return "Float" if t == 14
  return (__unbox_bool(v) ? "TrueClass" : "FalseClass") if t == 10
  __class_name(__ld(__unbox_obj_addr(v)))
end
