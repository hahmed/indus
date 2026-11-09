# format / sprintf / printf / String#%, in Ruby. Supports %d %i %s %f %x %o %b %c %e %%
# with flags - 0 + space, width and precision. Arguments arrive as a :dyn array.
def __format(fmt, args)
  out = ""
  ai = 0
  i = 0
  n = fmt.length
  while i < n
    c = __ld8(fmt, i)
    if c != 37 # not %
      out = out + fmt[i, 1]
      i = i + 1
    else
      i = i + 1
      left = false; zero = false; plus = false; space = false; alt = false
      while i < n && (__ld8(fmt, i) == 45 || __ld8(fmt, i) == 48 || __ld8(fmt, i) == 43 || __ld8(fmt, i) == 32 || __ld8(fmt, i) == 35)
        f = __ld8(fmt, i)
        left = true if f == 45
        zero = true if f == 48
        plus = true if f == 43
        space = true if f == 32
        alt = true if f == 35 # '#': 0x / 0b / 0 prefixes
        i = i + 1
      end
      width = 0
      while i < n && __ld8(fmt, i) >= 48 && __ld8(fmt, i) <= 57
        width = width * 10 + (__ld8(fmt, i) - 48)
        i = i + 1
      end
      prec = -1
      if i < n && __ld8(fmt, i) == 46
        i = i + 1
        prec = 0
        while i < n && __ld8(fmt, i) >= 48 && __ld8(fmt, i) <= 57
          prec = prec * 10 + (__ld8(fmt, i) - 48)
          i = i + 1
        end
      end
      conv = __ld8(fmt, i)
      i = i + 1
      if conv == 37
        out = out + "%"
      else
        arg = args[ai]
        ai = ai + 1
        body = ""
        if conv == 100 || conv == 105 # d i
          body = __fmt_int(__dyn_to_int(arg), 10, plus, space)
        elsif conv == 120 # x
          body = __fmt_int(__dyn_to_int(arg), 16, plus, space)
          body = "0x" + body if alt
        elsif conv == 88 # X
          body = __str_upcase(__fmt_int(__dyn_to_int(arg), 16, plus, space))
          body = "0X" + body if alt
        elsif conv == 111 # o
          body = __fmt_int(__dyn_to_int(arg), 8, plus, space)
          body = "0" + body if alt
        elsif conv == 98 # b
          body = __fmt_int(__dyn_to_int(arg), 2, plus, space)
          body = "0b" + body if alt
        elsif conv == 112 # p: inspect
          body = __dyn_inspect(arg)
        elsif conv == 103 # g: %e when the exponent is < -4 or >= precision, else %f without trailing zeros
          fv = __dyn_to_f(arg)
          pr = prec < 0 ? 6 : prec
          pr = 1 if pr == 0
          ex = fv == 0.0 ? 0 : __num_floor(__log10_abs(fv))
          if ex < -4 || ex >= pr
            body = __fmt_exp(fv, pr - 1)
            body = __strip_exp_zeros(body)
          else
            body = __fmt_float(fv, pr - 1 - ex, plus, space)
            body = __strip_trailing_zeros(body)
          end
        elsif conv == 102 # f
          body = __fmt_float(__dyn_to_f(arg), prec < 0 ? 6 : prec, plus, space)
        elsif conv == 101 # e
          body = __fmt_exp(__dyn_to_f(arg), prec < 0 ? 6 : prec)
        elsif conv == 115 # s
          body = __dyn_to_s(arg)
          body = body[0, prec] if prec >= 0 && prec < body.length
        elsif conv == 99 # c: a codepoint, or the first character of a string
          body = __tag(arg) == 2 ? __str_chr(__dyn_to_s(arg)) : __utf8_encode(__dyn_to_int(arg))
        else
          __trap
        end
        pad = width - body.length
        if pad > 0
          if left
            body = body + __spaces(pad, 32)
          elsif zero && conv != 115
            sign = body.length > 0 && (__ld8(body, 0) == 45 || __ld8(body, 0) == 43) ? body[0, 1] : ""
            body = sign + __spaces(pad, 48) + body[sign.length, body.length - sign.length]
          else
            body = __spaces(pad, 32) + body
          end
        end
        out = out + body
      end
    end
  end
  out
end

def __spaces(n, ch)
  s = __salloc(n)
  i = 0
  while i < n
    __st8(s, i, ch)
    i = i + 1
  end
  s
end

def __fmt_int(v, base, plus, space)
  neg = v < 0
  v = 0 - v if neg
  digits = ""
  if v == 0
    digits = "0"
  end
  while v > 0
    d = v % base
    digits = (d < 10 ? (48 + d).chr : (87 + d).chr) + digits
    v = v / base
  end
  return "-" + digits if neg
  return "+" + digits if plus
  return " " + digits if space
  digits
end

def __fmt_float(f, prec, plus, space)
  neg = f < 0.0
  f = 0.0 - f if neg
  scale = 1.0
  k = 0
  while k < prec
    scale = scale * 10.0
    k = k + 1
  end
  x = f * scale
  total = (x + 0.5).to_i
  total = total - 1 if x + 0.5 == total.to_f && total % 2 == 1 # exact halves round to even, like printf
  ip = total / scale.to_i
  fp = total - ip * scale.to_i
  s = ip.to_s
  if prec > 0
    frac = fp.to_s
    frac = "0" + frac while frac.length < prec
    s = s + "." + frac
  end
  return "-" + s if neg
  return "+" + s if plus
  return " " + s if space
  s
end

def __fmt_exp(f, prec)
  return __fmt_float(0.0, prec, false, false) + "e+00" if f == 0.0
  neg = f < 0.0
  f = 0.0 - f if neg
  e = 0
  while f >= 10.0
    f = f / 10.0
    e = e + 1
  end
  while f < 1.0
    f = f * 10.0
    e = e - 1
  end
  m = __fmt_float(f, prec, false, false)
  es = (e < 0 ? 0 - e : e).to_s
  es = "0" + es if es.length < 2
  (neg ? "-" : "") + m + "e" + (e < 0 ? "-" : "+") + es
end

def __dyn_to_int(v)
  t = __tag(v)
  return __unbox_int(v) if t & 1 == 1
  return __unbox_float(v).to_i if t == 14
  __trap
  0
end

def __dyn_to_f(v)
  t = __tag(v)
  return __unbox_int(v).to_f if t & 1 == 1
  return __unbox_float(v) if t == 14
  __trap
  0.0
end

def __log10_abs(f)
  a = f < 0.0 ? 0.0 - f : f
  e = 0
  while a >= 10.0
    a = a / 10.0
    e = e + 1
  end
  while a < 1.0
    a = a * 10.0
    e = e - 1
  end
  e.to_f
end
# "1.230000" -> "1.23", "2.000" -> "2"
def __strip_trailing_zeros(s)
  return s unless __str_include_p(s, ".")
  n = s.length
  while n > 0 && __ld8(s, n - 1) == 48
    n = n - 1
  end
  n = n - 1 if n > 0 && __ld8(s, n - 1) == 46
  s[0, n]
end
# "1.230000e-04" -> "1.23e-04"
def __strip_exp_zeros(s)
  at = __str_index_from(s, "e", 0)
  return s if at < 0
  __strip_trailing_zeros(s[0, at]) + s[at, s.length - at]
end
