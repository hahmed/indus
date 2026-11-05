# Math in Ruby, for binaries with no libc: sin, cos, exp, log, pow.
#
# The algorithms are fdlibm's (Sun, 1993; the ones every libm descends from): Cody-Waite
# argument reduction by pi/2 in three parts, then minimax polynomials on [-pi/4, pi/4].
# exp and log are fdlibm's too; all four within 1 ulp of libm (test/host/libm_test.rb).
# pow is binary powering for integer exponents (~10 ulp) and exp(y * log(x)) otherwise
# (~100 ulp: log's rounding times y; fdlibm's pow carries log2 in double-double to avoid
# this and is the next step). In-process the real libm is called; this is the standalone
# fallback, so a standalone binary's pow can differ from CRuby's in the last digits.

LIBM_PIO2_1  = 1.57079632673412561417e+00  # first 33 bits of pi/2
LIBM_PIO2_1T = 6.07710050650619224932e-11  # pi/2 - PIO2_1
LIBM_PIO2_2  = 6.07710050630396597660e-11  # second 33 bits
LIBM_PIO2_2T = 2.02226624879595063154e-21
LIBM_PIO2_3  = 2.02226624871116645580e-21  # third 33 bits
LIBM_PIO2_3T = 8.47842766036889956997e-32
LIBM_INVPIO2 = 6.36619772367581382433e-01

# sin on [-pi/4, pi/4]; y is the tail of x
def __libm_ksin(x, y, iy)
  z = x * x
  v = z * x
  r = 1.58969099521155010221e-10 * z - 2.50507602534068634195e-08
  r = r * z + 2.75573137070700676789e-06
  r = r * z - 1.98412698298579493134e-04
  r = r * z + 8.33333333332248946124e-03
  if iy == 0
    x + v * (-1.66666666666666324348e-01 + z * r)
  else
    x - ((z * (0.5 * y - v * r) - y) - v * -1.66666666666666324348e-01)
  end
end

# cos on [-pi/4, pi/4]
def __libm_kcos(x, y)
  z = x * x
  r = -1.13596475577881948265e-11 * z + 2.08757232129817482790e-09
  r = r * z - 2.75573143513906633035e-07
  r = r * z + 2.48015872894767294178e-05
  r = r * z - 1.38888888888741095749e-03
  r = r * z + 4.16666666666666019037e-02
  r = z * r
  hz = 0.5 * z
  w = 1.0 - hz
  w + (((1.0 - w) - hz) + (z * r - x * y))
end

# x reduced into [-pi/4, pi/4]: out[0] the head, out[1] the tail; returns the quadrant.
# Medium range only (|x| < 2^20 * pi/2): beyond that fdlibm's Payne-Hanek is needed.
def __libm_rem_pio2(x, out)
  ax = x < 0.0 ? -x : x
  if ax <= 0.78539816339744830962
    out[0] = x; out[1] = 0.0
    return 0
  end
  if ax >= 1647099.0
    return __libm_rem_pio2_large(x, out)
  end
  n = (ax * LIBM_INVPIO2 + 0.5).to_i
  fn = n.to_f
  r = ax - fn * LIBM_PIO2_1
  w = fn * LIBM_PIO2_1T
  y0 = r - w
  # the first stage loses bits when x is near a multiple of pi/2: refine with the next parts
  if __libm_exp_bits(y0) < __libm_exp_bits(ax) - 16
    t = r
    w = fn * LIBM_PIO2_2
    r = t - w
    w = fn * LIBM_PIO2_2T - ((t - r) - w)
    y0 = r - w
    if __libm_exp_bits(y0) < __libm_exp_bits(ax) - 49
      t = r
      w = fn * LIBM_PIO2_3
      r = t - w
      w = fn * LIBM_PIO2_3T - ((t - r) - w)
      y0 = r - w
    end
  end
  y1 = (r - y0) - w
  if x < 0.0
    out[0] = -y0; out[1] = -y1
    return -n
  end
  out[0] = y0; out[1] = y1
  n
end

# 2/pi as 64-bit limbs of its fraction (Payne-Hanek needs the bits far to the right)
LIBM_TWO_OVER_PI = [0xa2f9836e4e441529, 0xfc2757d1f534ddc0, 0xdb6295993c439041, 0xfe5163abdebbc561, 0xb7246e3a424dd2e0, 0x06492eea09d1921c]

# |x| large: x = m * 2^e exactly (m the 53-bit significand). x * 2/pi mod 4 is what the
# quadrant and the remainder need: take the bits of 2/pi from position e-2 onward (the
# earlier ones only add multiples of 4), 128 of them, multiply by m, keep the fraction.
def __libm_rem_pio2_large(x, out)
  bits = __fbits(x)
  m = (bits & 0x000fffffffffffff) | 0x0010000000000000
  e = ((bits >> 52) & 0x7ff) - 1075 # x = m * 2^e
  skip = e - 2 # bits of 2/pi at positions < e-2 only add multiples of 4 (m is an integer)
  skip = 0 if skip < 0
  li = skip / 64
  sh = skip % 64
  __trap if li + 2 >= LIBM_TWO_OVER_PI.length # |x| beyond 2^260: not reduced here
  w0 = __libm_window(li, sh)
  w1 = __libm_window(li + 1, sh)
  # P = m * (w0:w1), 181 bits: p0h:mid:p1l with mid = p0l + p1h (carry into p0h)
  p0h = __umulh(m, w0); p0l = __wmul(m, w0)
  p1h = __umulh(m, w1); p1l = __wmul(m, w1)
  mid = __wadd(p0l, p1h)
  carry = __libm_ult(mid, p0l) ? 1 : 0
  p0h = __wadd(p0h, carry)
  # value = P * 2^(s - 128), s = e - skip in [-30, 2]: integer part (mod 4) and the 128-bit fraction
  s = e - skip
  if s == 2
    q = __wshl(p0h, 2) | __lsr(mid, 62)
    fh = __wshl(mid, 2) | __lsr(p1l, 62)
    fl = __wshl(p1l, 2)
  elsif s == 1
    q = __wshl(p0h, 1) | __lsr(mid, 63)
    fh = __wshl(mid, 1) | __lsr(p1l, 63)
    fl = __wshl(p1l, 1)
  elsif s == 0
    q = p0h; fh = mid; fl = p1l
  else # s < 0: shift the 128-bit (mid:p1l) right, the integer part is p0h's low bits shifted in
    r = -s
    q = __lsr(p0h, r)
    fh = __wshl(p0h, 64 - r) | __lsr(mid, r)
    fl = __wshl(mid, 64 - r) | __lsr(p1l, r)
  end
  # round to nearest: a fraction above 1/2 becomes f - 1 with the quadrant bumped
  neg = false
  if __lsr(fh, 63) == 1
    q = q + 1
    neg = true
    fl = __wadd(~fl, 1)
    fh = __wadd(~fh, fl == 0 ? 1 : 0)
  end
  # f * pi/2 as a double: fh/2^64 (+ fl/2^128), times pi/2 in two parts
  fhd = __libm_u64_to_f(fh) * (2.0 ** -64)
  fld = __libm_u64_to_f(fl) * (2.0 ** -128)
  f = fhd + fld
  r = f * 1.5707963267948966 + f * 6.123233995736766e-17
  r = -r if neg
  if x < 0.0
    r = -r
    q = -q
  end
  out[0] = r; out[1] = 0.0
  q & 3
end

def __libm_ult(a, b) # unsigned a < b
  (a ^ -9223372036854775808) < (b ^ -9223372036854775808)
end

def __libm_window(li, sh)
  a = LIBM_TWO_OVER_PI[li]
  return a if sh == 0
  b = LIBM_TWO_OVER_PI[li + 1]
  __wshl(a, sh) | __lsr(b, 64 - sh)
end

# an unsigned 64-bit word as a double (ints are signed)
def __libm_u64_to_f(u)
  if u < 0 # top bit set
    (__lsr(u, 1) | (u & 1)).to_f * 2.0
  else
    u.to_f
  end
end

# the biased exponent field of a double
def __libm_exp_bits(f) = (__fbits(f) >> 52) & 0x7ff

def __libm_sin(x)
  return x - x if x != x || x > 1.0e308 || x < -1.0e308 # NaN, Inf
  out = [0.0, 0.0]
  n = __libm_rem_pio2(x, out)
  case n & 3
  when 0 then __libm_ksin(out[0], out[1], 1)
  when 1 then __libm_kcos(out[0], out[1])
  when 2 then -__libm_ksin(out[0], out[1], 1)
  else -__libm_kcos(out[0], out[1])
  end
end

def __libm_cos(x)
  return x - x if x != x || x > 1.0e308 || x < -1.0e308
  out = [0.0, 0.0]
  n = __libm_rem_pio2(x, out)
  case n & 3
  when 0 then __libm_kcos(out[0], out[1])
  when 1 then -__libm_ksin(out[0], out[1], 1)
  when 2 then -__libm_kcos(out[0], out[1])
  else __libm_ksin(out[0], out[1], 1)
  end
end

# 2^k * f, by the exponent field (f normal, result normal)
def __libm_scalbn(f, k)
  bits = __fbits(f)
  e = ((bits >> 52) & 0x7ff) + k
  return 0.0 if e <= 0
  return (f < 0.0 ? -1.0e308 * 10.0 : 1.0e308 * 10.0) if e >= 0x7ff
  __ffrom((bits & (0x800fffffffffffff)) | (e << 52))
end

def __libm_exp(x)
  return x if x != x
  return 1.0e308 * 10.0 if x > 709.782712893384
  return 0.0 if x < -745.1332191019412
  return 1.0 + x if x < 2.0 ** -28 && x > -(2.0 ** -28)
  ln2hi = 6.93147180369123816490e-01
  ln2lo = 1.90821492927058770002e-10
  k = (x * 1.44269504088896338700e+00 + (x < 0.0 ? -0.5 : 0.5)).to_i
  kf = k.to_f
  hi = x - kf * ln2hi
  lo = kf * ln2lo
  r = hi - lo
  t = r * r
  c = r - t * (1.66666666666666019037e-01 + t * (-2.77777777770155933842e-03 + t * (6.61375632143793436117e-05 + t * (-1.65339022054652515390e-06 + t * 4.13813679705723846039e-08))))
  y = 1.0 - ((lo - (r * c) / (2.0 - c)) - hi)
  k == 0 ? y : __libm_scalbn(y, k)
end

def __libm_log(x)
  return x if x != x
  return -1.0e308 * 10.0 if x == 0.0
  return 0.0 / 0.0 if x < 0.0
  return x if x > 1.0e308
  bits = __fbits(x)
  k = ((bits >> 52) & 0x7ff)
  if k == 0 # subnormal: scale up
    x = x * (2.0 ** 54)
    bits = __fbits(x)
    k = ((bits >> 52) & 0x7ff) - 54
  end
  k = k - 1023
  # f in [sqrt(2)/2, sqrt(2))
  hx = (bits >> 32) & 0xfffff
  i = (hx + 0x95f64) & 0x100000
  m = __ffrom(((bits & 0xffffffff) | ((hx | (i ^ 0x3ff00000)) << 32)))
  k = k + (i >> 20)
  f = m - 1.0
  kf = k.to_f
  ln2hi = 6.93147180369123816490e-01
  ln2lo = 1.90821492927058770002e-10
  if (0x000fffff & (2 + hx)) < 3 # |f| < 2^-20
    if f == 0.0
      return k == 0 ? 0.0 : kf * ln2hi + kf * ln2lo
    end
    r = f * f * (0.5 - 0.33333333333333333 * f)
    return k == 0 ? f - r : kf * ln2hi - ((r - kf * ln2lo) - f)
  end
  s = f / (2.0 + f)
  z = s * s
  w = z * z
  t1 = w * (3.999999999940941908e-01 + w * (2.222219843214978396e-01 + w * 1.531383769920937332e-01))
  t2 = z * (6.666666666666735130e-01 + w * (2.857142874366239149e-01 + w * (1.818357216161805012e-01 + w * 1.479819860511658591e-01)))
  r = t2 + t1
  hfsq = 0.5 * f * f
  if k == 0
    f - (hfsq - s * (hfsq + r))
  else
    kf * ln2hi - ((hfsq - (s * (hfsq + r) + kf * ln2lo)) - f)
  end
end

# x ** y: exact for integer y by binary powering; exp(y log x) otherwise
def __libm_pow(x, y)
  return 1.0 if y == 0.0
  return x if y == 1.0
  if y == y.to_i.to_f && y < 1024.0 && y > -1024.0
    n = y.to_i
    neg = n < 0
    n = -n if neg
    acc = 1.0
    base = x
    while n > 0
      acc = acc * base if n & 1 == 1
      base = base * base
      n = n >> 1
    end
    return neg ? 1.0 / acc : acc
  end
  return 0.0 / 0.0 if x < 0.0 # a non-integer power of a negative number
  __libm_exp(y * __libm_log(x))
end
