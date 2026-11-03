# Core routines written in the Indus subset and compiled into every program.
# Testable with plain Ruby: `ruby -r ./lib/indus/prelude/core.rb`.

def __trap = raise("indus: trap") # the intrinsic traps in compiled code; plain Ruby raises

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
  # denormals: 10**-324 is not representable; lift into the normal range first
  # (inexact in the last place for the very smallest values -- a known limit)
  lift = 0
  if a < 1.0e-290
    a = a * 1.0e100
    lift = 100
  end
  e = __dec_exp(a)
  digits = 0
  p = 1
  found = 0
  while p <= 17 && found == 0
    # the integer with p significant digits nearest to a: k = e-p+1 is the
    # power of ten to strip. Multiply or divide by an *exact* power of ten so
    # both the scaling and the parse-back are correctly rounded.
    k = e - p + 1
    q = k >= 0 ? a / __pow10(k) : a * __pow10(0 - k)
    n = __round_f(q)
    e2 = e
    if n >= __pow10(p).to_i
      # rounding carried into a new digit (9.95 -> 10 at p=2): for this try only
      n = n / 10
      e2 = e + 1
      k = k + 1
    end
    # double rounding can land one off: try the neighbours too (nearest first)
    c = 0
    while c < 3 && found == 0
      m = c == 0 ? n : (c == 1 ? n - 1 : n + 1)
      back = k >= 0 ? m.to_f * __pow10(k) : m.to_f / __pow10(0 - k)
      # the check is only meaningful when m and 10**|k| are exact doubles
      if back == a && m > 0 && m < 9007199254740992 && k <= 22 && k >= -22
        digits = m
        e = e2
        found = 1
      end
      c = c + 1
    end
    p = p + 1 if found == 0
  end
  if found == 0
    # 17 significant digits cannot be produced exactly with double arithmetic;
    # printing an approximation would be a wrong answer. Fail noisily until the
    # exact algorithm (Grisu) lands.
    __trap
  end
  e = e - lift
  ds = digits.to_s
  # strip trailing zeros from the significand
  while ds.length > 1 && ds[ds.length - 1] == "0"
    ds = ds[0, ds.length - 1]
  end
  out = ""
  if e >= -4 && e < 15
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
