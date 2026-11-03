GRISU_F = [
  0xfa8fd5a0081c0288, 0xbaaee17fa23ebf76, 0x8b16fb203055ac76, 0xcf42894a5dce35ea,
  0x9a6bb0aa55653b2d, 0xe61acf033d1a45df, 0xab70fe17c79ac6ca, 0xff77b1fcbebcdc4f,
  0xbe5691ef416bd60c, 0x8dd01fad907ffc3c, 0xd3515c2831559a83, 0x9d71ac8fada6c9b5,
  0xea9c227723ee8bcb, 0xaecc49914078536d, 0x823c12795db6ce57, 0xc21094364dfb5637,
  0x9096ea6f3848984f, 0xd77485cb25823ac7, 0xa086cfcd97bf97f4, 0xef340a98172aace5,
  0xb23867fb2a35b28e, 0x84c8d4dfd2c63f3b, 0xc5dd44271ad3cdba, 0x936b9fcebb25c996,
  0xdbac6c247d62a584, 0xa3ab66580d5fdaf6, 0xf3e2f893dec3f126, 0xb5b5ada8aaff80b8,
  0x87625f056c7c4a8b, 0xc9bcff6034c13053, 0x964e858c91ba2655, 0xdff9772470297ebd,
  0xa6dfbd9fb8e5b88f, 0xf8a95fcf88747d94, 0xb94470938fa89bcf, 0x8a08f0f8bf0f156b,
  0xcdb02555653131b6, 0x993fe2c6d07b7fac, 0xe45c10c42a2b3b06, 0xaa242499697392d3,
  0xfd87b5f28300ca0e, 0xbce5086492111aeb, 0x8cbccc096f5088cc, 0xd1b71758e219652c,
  0x9c40000000000000, 0xe8d4a51000000000, 0xad78ebc5ac620000, 0x813f3978f8940984,
  0xc097ce7bc90715b3, 0x8f7e32ce7bea5c70, 0xd5d238a4abe98068, 0x9f4f2726179a2245,
  0xed63a231d4c4fb27, 0xb0de65388cc8ada8, 0x83c7088e1aab65db, 0xc45d1df942711d9a,
  0x924d692ca61be758, 0xda01ee641a708dea, 0xa26da3999aef774a, 0xf209787bb47d6b85,
  0xb454e4a179dd1877, 0x865b86925b9bc5c2, 0xc83553c5c8965d3d, 0x952ab45cfa97a0b3,
  0xde469fbd99a05fe3, 0xa59bc234db398c25, 0xf6c69a72a3989f5c, 0xb7dcbf5354e9bece,
  0x88fcf317f22241e2, 0xcc20ce9bd35c78a5, 0x98165af37b2153df, 0xe2a0b5dc971f303a,
  0xa8d9d1535ce3b396, 0xfb9b7cd9a4a7443c, 0xbb764c4ca7a44410, 0x8bab8eefb6409c1a,
  0xd01fef10a657842c, 0x9b10a4e5e9913129, 0xe7109bfba19c0c9d, 0xac2820d9623bf429,
  0x80444b5e7aa7cf85, 0xbf21e44003acdd2d, 0x8e679c2f5e44ff8f, 0xd433179d9c8cb841,
  0x9e19db92b4e31ba9, 0xeb96bf6ebadf77d9, 0xaf87023b9bf0ee6b
]
GRISU_E = [
  -1220, -1193, -1166, -1140, -1113, -1087, -1060, -1034, -1007, -980, -954, -927,
  -901, -874, -847, -821, -794, -768, -741, -715, -688, -661, -635, -608,
  -582, -555, -529, -502, -475, -449, -422, -396, -369, -343, -316, -289,
  -263, -236, -210, -183, -157, -130, -103, -77, -50, -24, 3, 30,
  56, 83, 109, 136, 162, 189, 216, 242, 269, 295, 322, 348,
  375, 402, 428, 455, 481, 508, 534, 561, 588, 614, 641, 667,
  694, 720, 747, 774, 800, 827, 853, 880, 907, 933, 960, 986,
  1013, 1039, 1066
]

# Grisu2 (Loitsch 2010): the shortest decimal that round-trips, with 64-bit
# integer arithmetic and the cached powers above. Written in the Indus subset.
# Unsigned 64-bit values live in Integers as bit patterns; the __u* intrinsics
# do the unsigned/wrapping operations (umulh, lsr, clz, wrapping add/sub/mul,
# unsigned compare). Plain-Ruby stand-ins for testing are in grisu_host.rb.
#
# Returns the digits as an Integer (1..17 digits) and sets the decimal
# exponent K via __grisu_k (the subset has no multiple return values):
#   value = digits * 10**K

def __grisu_k
  __gget_int(:__grisu_k)
end

# DiyFp multiply: (af * bf) >> 64, rounded
def __diy_mul(af, bf)
  h = __umulh(af, bf)
  l = __wmul(af, bf)
  __wadd(h, __lsr(l, 63) & 1)
end

def __grisu(value)
  bits = __fbits(value)
  biased = __lsr(bits, 52) & 2047
  frac = bits & 4503599627370495          # 2**52 - 1
  f = biased == 0 ? frac : frac + 4503599627370496
  e = biased == 0 ? -1074 : biased - 1075
  # boundaries m+ = (2f+1, e-1); m- = (2f-1, e-1) or (4f-1, e-2) at a power of two
  mp_f = __wadd(__wmul(f, 2), 1)
  mp_e = e - 1
  if f == 4503599627370496 && biased > 1
    mm_f = __wsub(__wmul(f, 4), 1)
    mm_e = e - 2
  else
    mm_f = __wsub(__wmul(f, 2), 1)
    mm_e = e - 1
  end
  # normalize m+
  s = __clz(mp_f)
  mp_f = __wmul(mp_f, __pow2(s))
  mp_e = mp_e - s
  # bring m- to the same exponent
  mm_f = __wmul(mm_f, __pow2(mm_e - mp_e))
  mm_e = mp_e
  # normalize v
  s = __clz(f)
  vf = __wmul(f, __pow2(s))
  ve = e - s
  # cached power: alpha=-59, gamma=-32 for mp_e; k = ceil((alpha - mp_e - 63) * log10(2))
  dk = (0 - 61 - mp_e) * 0.30102999566398114 + 347.0
  k = dk.to_i
  k = k + 1 if dk - k.to_f > 0.0
  index = (k / 8) + 1
  cf = GRISU_F[index]
  ce = GRISU_E[index]
  bigk = 0 - (0 - 348 + index * 8)
  w_f = __diy_mul(vf, cf)
  wp_f = __diy_mul(mp_f, cf)
  wm_f = __diy_mul(mm_f, cf)
  we = mp_e + ce + 64
  wm_f = __wadd(wm_f, 1)
  wp_f = __wsub(wp_f, 1)
  delta = __wsub(wp_f, wm_f)
  wpw = __wsub(wp_f, w_f)           # Mp - W
  # digit generation
  one_f = __pow2(0 - we)            # 1 << -we   (we in [-60, -32])
  p1 = __lsr(wp_f, 0 - we)
  p2 = wp_f & (one_f - 1)
  kappa = __count_digits(p1)
  digits = 0
  len = 0
  result_k = 0
  done = 0
  while kappa > 0 && done == 0
    pk = __ipow10(kappa - 1)
    d = p1 / pk
    p1 = p1 % pk
    if d > 0 || len > 0
      digits = digits * 10 + d
      len = len + 1
    end
    kappa = kappa - 1
    tmp = __wadd(__wmul(p1, one_f), p2)
    if __ule(tmp, delta)
      result_k = bigk + kappa
      digits = __grisu_round(digits, len, delta, tmp, __wmul(__ipow10(kappa), one_f), wpw)
      done = 1
    end
  end
  while done == 0
    p2 = __wmul(p2, 10)
    delta = __wmul(delta, 10)
    d = __lsr(p2, 0 - we)
    if d > 0 || len > 0
      digits = digits * 10 + d
      len = len + 1
    end
    p2 = p2 & (one_f - 1)
    kappa = kappa - 1
    if __ult(p2, delta)
      result_k = bigk + kappa
      digits = __grisu_round(digits, len, delta, p2, one_f, __wmul(wpw, __ipow10(0 - kappa)))
      done = 1
    end
  end
  __gset_int(:__grisu_k, result_k)
  digits
end

# weed: nudge the last digit down while the result stays within the boundary
# and closer to the true value
def __grisu_round(digits, len, delta, rest, ten_kappa, wpw)
  # all unsigned 64-bit comparisons
  while __ult(rest, wpw) && __ule(ten_kappa, __wsub(delta, rest)) && (__ult(__wadd(rest, ten_kappa), wpw) || __ult(__wsub(__wadd(rest, ten_kappa), wpw), __wsub(wpw, rest)))
    digits = digits - 1
    rest = __wadd(rest, ten_kappa)
  end
  digits
end

def __count_digits(n)
  c = 0
  while n > 0
    n = n / 10
    c = c + 1
  end
  c
end

def __ipow10(k)
  r = 1
  while k > 0
    r = r * 10
    k = k - 1
  end
  r
end

def __pow2(k)
  r = 1
  while k > 0
    r = __wmul(r, 2)
    k = k - 1
  end
  r
end
