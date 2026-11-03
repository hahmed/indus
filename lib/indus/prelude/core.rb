# Core routines written in the Indus subset and compiled into every program.
# Testable with plain Ruby: `ruby -r ./lib/indus/prelude/core.rb`.


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
