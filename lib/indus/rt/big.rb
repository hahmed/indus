# Bignum, in Ruby, for Indus. A number is an array of Integers:
#   [sign, limb0, limb1, ...]   sign 0 or 1; limbs base 2**31, little-endian,
#   no leading zero limbs; zero is [0].
# Base 2**31, not 2**32: compiled Integers are checked signed 64-bit, and a
# 32x32 limb product plus carries reaches past 2**63 and traps. With 31-bit
# limbs every intermediate stays below 2**62. The same code runs under CRuby
# (test/host/big_test.rb), whose Integers would have hidden that.
BIG_BASE = 2147483648
BIG_BITS = 31

def __big_from_int(i)
  return [0] if i == 0
  sign = 0
  if i < 0
    sign = 1
    i = 0 - i
  end
  out = [sign]
  while i > 0
    out.push(i % BIG_BASE)
    i = i / BIG_BASE
  end
  out
end

def __big_zero_p(a)
  a.length == 1
end

# magnitude compare: -1, 0, 1
def __big_cmp_mag(a, b)
  return -1 if a.length < b.length
  return 1 if a.length > b.length
  i = a.length - 1
  while i >= 1
    return -1 if a[i] < b[i]
    return 1 if a[i] > b[i]
    i = i - 1
  end
  0
end

def __big_cmp(a, b)
  za = __big_zero_p(a)
  zb = __big_zero_p(b)
  return 0 if za && zb
  return (b[0] == 1 ? 1 : -1) if za
  return (a[0] == 1 ? -1 : 1) if zb
  return (a[0] == 1 ? -1 : 1) if a[0] != b[0]
  c = __big_cmp_mag(a, b)
  a[0] == 1 ? 0 - c : c
end

def __big_eq(a, b)
  __big_cmp(a, b) == 0
end

# |a| + |b| with the given sign
def __big_add_mag(a, b, sign)
  n = a.length > b.length ? a.length : b.length
  out = [sign]
  carry = 0
  i = 1
  while i < n
    s = carry
    s = s + a[i] if i < a.length
    s = s + b[i] if i < b.length
    out.push(s % BIG_BASE)
    carry = s / BIG_BASE
    i = i + 1
  end
  out.push(carry) if carry > 0
  out
end

# |a| - |b| with |a| >= |b|, given sign
def __big_sub_mag(a, b, sign)
  out = [sign]
  borrow = 0
  i = 1
  while i < a.length
    s = a[i] - borrow
    s = s - b[i] if i < b.length
    if s < 0
      s = s + BIG_BASE
      borrow = 1
    else
      borrow = 0
    end
    out.push(s)
    i = i + 1
  end
  __big_trim(out)
end

def __big_trim(a)
  a.pop while a.length > 1 && a[a.length - 1] == 0
  a[0] = 0 if a.length == 1
  a
end

def __big_add(a, b)
  return __big_dup(b) if __big_zero_p(a)
  return __big_dup(a) if __big_zero_p(b)
  return __big_add_mag(a, b, a[0]) if a[0] == b[0]
  c = __big_cmp_mag(a, b)
  return [0] if c == 0
  c > 0 ? __big_sub_mag(a, b, a[0]) : __big_sub_mag(b, a, b[0])
end

def __big_neg(a)
  return [0] if __big_zero_p(a)
  out = __big_dup(a)
  out[0] = 1 - a[0]
  out
end

def __big_sub(a, b)
  __big_add(a, __big_neg(b))
end

def __big_dup(a)
  out = []
  i = 0
  while i < a.length
    out.push(a[i])
    i = i + 1
  end
  out
end

def __big_mul(a, b)
  return [0] if __big_zero_p(a) || __big_zero_p(b)
  n = a.length - 1
  m = b.length - 1
  out = Array.new(n + m + 1, 0)
  out[0] = a[0] == b[0] ? 0 : 1
  i = 1
  while i <= n
    carry = 0
    j = 1
    while j <= m
      cur = out[i + j - 1] + a[i] * b[j] + carry
      out[i + j - 1] = cur % BIG_BASE
      carry = cur / BIG_BASE
      j = j + 1
    end
    out[i + m] = out[i + m] + carry
    i = i + 1
  end
  __big_trim(out)
end

# |a| / small (0 < small < 2**31) -> quotient; the remainder is left in rem[0]
# (a one-element array: the prelude keeps every array homogeneous)
def __big_divmod_small(a, small, rem)
  q = Array.new(a.length, 0)
  q[0] = a[0]
  r = 0
  i = a.length - 1
  while i >= 1
    cur = r * BIG_BASE + a[i]
    q[i] = cur / small
    r = cur % small
    i = i - 1
  end
  rem[0] = r
  __big_trim(q)
end

# magnitude shift left by one bit
def __big_shl1(a)
  out = [a[0]]
  carry = 0
  i = 1
  while i < a.length
    v = a[i] * 2 + carry
    out.push(v % BIG_BASE)
    carry = v / BIG_BASE
    i = i + 1
  end
  out.push(carry) if carry > 0
  out
end

def __big_bits(a)
  return 0 if __big_zero_p(a)
  top = a[a.length - 1]
  n = 0
  while top > 0
    top = top / 2
    n = n + 1
  end
  (a.length - 2) * BIG_BITS + n
end

def __big_bit(a, k)
  limb = k / BIG_BITS + 1
  return 0 if limb >= a.length
  (a[limb] / (1 << (k % BIG_BITS))) % 2
end

# truncated division of magnitudes by binary long division -> q; the remainder is left in rout[0]
def __big_divmod_mag(a, b, rout)
  q = [0]
  r = [0]
  k = __big_bits(a) - 1
  while k >= 0
    r = __big_shl1(r)
    if __big_bit(a, k) == 1
      r = __big_add_mag(r, [0, 1], 0)
    end
    q = __big_shl1(q)
    if __big_cmp_mag(r, b) >= 0
      r = __big_sub_mag(r, b, 0)
      q = __big_add_mag(q, [0, 1], 0)
    end
    k = k - 1
  end
  rout[0] = __big_trim(r)
  __big_trim(q)
end

# Ruby's floor division
def __big_div(a, b)
  __trap if __big_zero_p(b)
  return [0] if __big_zero_p(a)
  if b.length == 2 && a[0] == 0 && b[0] == 0
    return __big_divmod_small(a, b[1], [0])
  end
  rout = [[0]]
  q = __big_divmod_mag(__big_abs(a), __big_abs(b), rout)
  if a[0] != b[0]
    q = __big_neg(q)
    q = __big_sub(q, [0, 1]) unless __big_zero_p(rout[0])
  end
  q
end

def __big_mod(a, b)
  __big_sub(a, __big_mul(__big_div(a, b), b))
end

def __big_abs(a)
  out = __big_dup(a)
  out[0] = 0
  out
end

def __big_to_s(a)
  return "0" if __big_zero_p(a)
  digits = []
  cur = __big_abs(a)
  rem = [0]
  while !__big_zero_p(cur)
    cur = __big_divmod_small(cur, 1000000000, rem)
    digits.push(rem[0])
  end
  out = a[0] == 1 ? "-" : ""
  i = digits.length - 1
  out = out + digits[i].to_s
  i = i - 1
  while i >= 0
    s = digits[i].to_s
    while s.length < 9
      s = "0" + s
    end
    out = out + s
    i = i - 1
  end
  out
end

# a Bignum that fits: back to an Integer (callers check __big_fits_p)
def __big_fits_p(a)
  __big_bits(a) <= 62
end

def __big_to_int(a)
  v = 0
  i = a.length - 1
  while i >= 1
    v = v * BIG_BASE + a[i]
    i = i - 1
  end
  a[0] == 1 ? 0 - v : v
end
