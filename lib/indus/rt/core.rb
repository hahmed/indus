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
    return __fbits(f) < 0 ? "-0.0" : "0.0" # the sign bit survives the compare
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
  return "nil" if __nil_str(s) # a String slot holding nil: s[100], h["missing"], a[9]
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
  if t == 6
    return __dyn_hash_inspect(__unbox_hash(v))
  end
  "#<object>"
end

# a tagged hash's inspect: keys and values are tagged too
def __dyn_hash_inspect(h)
  out = "{"
  i = 0
  while i < __hcount(h)
    out = out + ", " if i > 0
    k = __hkey_at(h, i)
    out = out + (__dyn_sym_p(k) ? __dyn_to_s(k) + ": " : __dyn_inspect(k) + " => ") + __dyn_inspect(__hval_at(h, i))
    i = i + 1
  end
  out + "}"
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
  if __tag(a) == 4 && __tag(b) == 4
    return __box_arr(__arr_plus(__unbox_arr(a), __unbox_arr(b)))
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
  return __str_chars(s) if sep.length == 0
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

# gsub with a string pattern: count the matches, size the result exactly, write it once.
# No match: a copy. (The old version concatenated per match: 260 bytes of garbage a call.)
def __str_gsub(s, pat, rep)
  if pat.length == 0 # the empty pattern matches before every character and at the end
    out = __salloc(s.length + (s.length + 1) * rep.length)
    w = 0
    k = 0
    while k < s.length
      w = __str_copy_bytes(out, w, rep, 0, rep.length)
      __st8(out, w, __ld8(s, k))
      w = w + 1
      k = k + 1
    end
    __str_copy_bytes(out, w, rep, 0, rep.length)
    return out
  end
  n = 0
  i = __str_index(s, pat, 0)
  while !i.nil?
    n = n + 1
    i = __str_index(s, pat, i + pat.length)
  end
  return __sdup(s) if n == 0
  out = __salloc(s.length + n * (rep.length - pat.length))
  w = 0
  start = 0
  i = __str_index(s, pat, 0)
  while !i.nil?
    w = __str_copy_bytes(out, w, s, start, i - start)
    w = __str_copy_bytes(out, w, rep, 0, rep.length)
    start = i + pat.length
    i = __str_index(s, pat, start)
  end
  __str_copy_bytes(out, w, s, start, s.length - start)
  out
end

# bytes src[from, n] into out at w; returns the new w
def __str_copy_bytes(out, w, src, from, n)
  k = 0
  while k < n
    __st8(out, w + k, __ld8(src, from + k))
    k = k + 1
  end
  w + n
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
  def to_s = @message
  def inspect = "#<" + self.class + ": " + @message + ">"
  def full_message = self.class + ": " + @message
  def backtrace = []
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
# catch/throw ride on the exception machinery: throw raises this, catch rescues it by tag
class IndusThrow < StandardError
  attr_reader :tag, :value
  def initialize(tag, value)
    @tag = tag
    @value = value
    @message = "uncaught throw"
  end
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
  def clamp(lo, hi)
    return lo if (self <=> lo) < 0
    return hi if (self <=> hi) > 0
    self
  end
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
  w = s.length
  while i < s.length
    n = __utf8_len(__ld8(s, i)) # a multibyte character keeps its byte order
    n = s.length - i if i + n > s.length
    w = w - n
    k = 0
    while k < n
      __st8(out, w + k, __ld8(s, i + k))
      k = k + 1
    end
    i = i + n
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
# "a-y" in a tr set: the range expanded; a leading ^ negates (characters NOT in the set map to to's last)
def __tr_expand(set)
  out = ""
  i = 0
  while i < set.length
    c = __ld8(set, i)
    if i + 2 < set.length && __ld8(set, i + 1) == 45 # a-z
      hi = __ld8(set, i + 2)
      while c <= hi
        out = out + c.chr
        c = c + 1
      end
      i = i + 3
    else
      out = out + set[i, 1]
      i = i + 1
    end
  end
  out
end
def __str_tr(s, from, to)
  if from.length > 0 && __ld8(from, 0) == 94 && from.length > 1 # ^set: everything not in the set
    keep = __tr_expand(from[1, from.length - 1])
    last = to.length > 0 ? __ld8(to, to.length - 1) : 32
    out = __sdup(s)
    i = 0
    while i < out.length
      __st8(out, i, last) unless __str_include_p(keep, out[i, 1])
      i = i + 1
    end
    return out
  end
  from = __tr_expand(from)
  to = __tr_expand(to)
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

# one element per UTF-8 character: the lead byte says how many bytes follow
def __utf8_len(b) = b < 128 ? 1 : (b >= 240 ? 4 : (b >= 224 ? 3 : (b >= 192 ? 2 : 1)))
def __str_chars(s)
  out = []
  i = 0
  while i < s.length
    n = __utf8_len(__ld8(s, i))
    n = s.length - i if i + n > s.length
    out.push(s[i, n])
    i = i + n
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

# a String's Symbol: symbols are ids assigned at compile time, so only names the program
# spells somewhere exist; anything else traps (a dynamic symbol the program never wrote)
def __str_to_sym(s)
  i = 1
  while i < SYMBOL_NAMES.length
    return __sym_of_id(i) if SYMBOL_NAMES[i] == s
    i = i + 1
  end
  # a name the program never spelled as a literal: intern it now (the table is a global array)
  __sym_of_id(__intern(__sdup(s)))
end

# s[i] = str: bytes replaced in place when the lengths match (one byte for one byte);
# a different length rebuilds the string's bytes (the handle is kept when it fits)
# s[i] = v on a String (a tagged receiver or index goes through __dyn_idx_set first, which
# unboxes: no representation is mixed inside here)
def __str_set_at(s, i, v)
  __str_set_bytes_i(s, i, v)
  s
end

def __str_set_bytes_i(s, i, v)
  i = s.length + i if i < 0
  __trap if i < 0 || i >= s.length
  if v.length == 1
    __st8(s, i, v.ord)
    return s
  end
  rest = s[i + 1, s.length - i - 1]
  head = s[0, i]
  rebuilt = head + v + rest
  __str_replace_bytes(s, rebuilt)
  s
end

# s takes rebuilt's bytes; traps when they do not fit s's capacity (no in-place growth of a
# string whose handle others hold)
def __str_replace_bytes(s, rebuilt)
  __trap if rebuilt.length > __ld(__handle(s) - 16)
  i = 0
  while i < rebuilt.length
    __st8(s, i, rebuilt[i].ord)
    i = i + 1
  end
  __st(__handle(s) - 8, rebuilt.length)
  s
end

# v[i] on a tagged value with an integer index: a string's character, an array's element
def __dyn_idx(v, i)
  t = __tag(v)
  return __box_str(__unbox_str(v)[i]) if t == 2
  return __unbox_arr(v)[i] if t == 4
  return __unbox_hash(v)[__box_int(i)] if t == 6
  __trap
  v
end

# v[i] = x on a tagged value: the string's byte(s), or the array's slot. Returns the container
# (the lowering rebinds the receiver's home to the result, as every []= does)
def __dyn_idx_set(v, i, x)
  t = __tag(v)
  if t == 2
    __str_set_at(__unbox_str(v), i, __dyn_str(x))
    return v
  end
  if t == 4
    a = __unbox_arr(v)
    __trap if i >= a.length # growth through a tagged handle would not be seen by its holders
    a[i] = x
    return v
  end
  __trap
  v
end


# dup of a tagged value: strings and arrays are copied, everything else is itself
def __dyn_dup(v)
  t = __tag(v)
  return __box_str(__str_dup(__unbox_str(v))) if t == 2
  return __box_arr(__arr_dup(__unbox_arr(v))) if t == 4
  v
end

# v[k] with a tagged key: an integer key indexes a string or array, anything else looks up a hash
def __dyn_idx_dyn(v, k)
  return __dyn_idx(v, __unbox_int(k)) if __tag(k) & 1 == 1
  __trap if __tag(v) != 6
  __unbox_hash(v)[k]
end
def __dyn_idx_set_dyn(v, k, x)
  return __dyn_idx_set(v, __unbox_int(k), x) if __tag(k) & 1 == 1
  __trap if __tag(v) != 6
  h = __unbox_hash(v)
  h[k] = x
  v
end

def __dyn_to_i(v)
  t = __tag(v)
  return __unbox_int(v) if t & 1 == 1
  return __unbox_str(v).to_i if t == 2
  return __unbox_float(v).to_i if t == 14
  return 0 if v == 0
  __trap
  0
end
def __dyn_to_f(v)
  t = __tag(v)
  return __unbox_int(v).to_f if t & 1 == 1
  return __unbox_str(v).to_f if t == 2
  return __unbox_float(v) if t == 14
  __trap
  0.0
end

# the Symbol for a name the program spells somewhere, or -1 (respond_to? of an unknown name)
def __str_to_sym_q(s)
  i = 1
  while i < SYMBOL_NAMES.length
    return __sym_of_id(i) if SYMBOL_NAMES[i] == s
    i = i + 1
  end
  __sym_of_id(0)
end

# split(sep, limit): a negative limit keeps trailing empty fields; a positive one caps the pieces
def __str_split2(s, sep, limit)
  return __str_split(s, sep) if limit == 0
  out = []
  if sep == " " # awk-style with a limit: fields on whitespace runs, the last piece is the untouched remainder
    i = 0
    while i < s.length
      while i < s.length && __str_space(__ld8(s, i))
        i = i + 1
      end
      return out if i >= s.length
      if limit > 0 && out.length == limit - 1
        out.push(s[i, s.length - i])
        return out
      end
      start = i
      while i < s.length && !__str_space(__ld8(s, i))
        i = i + 1
      end
      out.push(s[start, i - start])
    end
    return out
  end
  start = 0
  i = 0
  while i <= s.length - sep.length && sep.length > 0
    if limit > 0 && out.length == limit - 1
      i = s.length
    elsif __str_match_at(s, sep, i)
      out.push(s[start, i - start])
      i = i + sep.length
      start = i
    else
      i = i + 1
    end
  end
  out.push(s[start, s.length - start])
  out
end

# Float#%: floored modulo, the sign of the divisor (3.7 % 1 = 0.7, -3.7 % 1 = 0.3)
def __float_mod(a, b)
  fl = __num_floor(a / b)
  a - b * fl.to_f
end
def __float_divmod(a, b)
  q = __num_floor(a / b)
  [q, a - b * q.to_f]
end
def __float_floor1(f, digits)
  m = 1.0
  i = 0
  while i < digits
    m = m * 10.0
    i = i + 1
  end
  __num_floor(f * m).to_f / m
end
def __float_ceil1(f, digits)
  m = 1.0
  i = 0
  while i < digits
    m = m * 10.0
    i = i + 1
  end
  __num_ceil(f * m).to_f / m
end
# round(-n) on a Float: an Integer, to tens / hundreds
def __float_round_neg(f, digits)
  m = 1
  i = 0
  while i < 0 - digits
    m = m * 10
    i = i + 1
  end
  __float_round0(f / m.to_f) * m
end
