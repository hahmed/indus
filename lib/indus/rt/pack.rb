# Array#pack / String#unpack on byte strings. Directives: a A Z (strings), b B (bit strings), h H (hex),
# c C s S l L q Q n N v V j J (integers, little-endian unless n N / '>' says otherwise), U (UTF-8), w (BER),
# m (base64), u (uuencode), x (null byte), X (back up), @ (absolute position), with counts and '*'.
# Arguments arrive as a :dyn array (any element kinds); results of unpack are a :dyn array.

# fmt[i..] parses one directive: [letter position, mods start, mods end, count (-1 for *), next index, explicit count?]
# (integers only -- a mixed array would make every element :dyn)
def __pack_next(fmt, i)
  while i < fmt.length && (__ld8(fmt, i) == 32 || __ld8(fmt, i) == 10 || __ld8(fmt, i) == 9)
    i = i + 1
  end
  return nil if i >= fmt.length
  if __ld8(fmt, i) == 35 # a comment to end of line
    i = i + 1 while i < fmt.length && __ld8(fmt, i) != 10
    return __pack_next(fmt, i)
  end
  lp = i
  i = i + 1
  ms = i
  while i < fmt.length && (__ld8(fmt, i) == 95 || __ld8(fmt, i) == 33 || __ld8(fmt, i) == 60 || __ld8(fmt, i) == 62) # _ ! < >
    i = i + 1
  end
  me = i
  count = 1
  explicit = 0
  if i < fmt.length && __ld8(fmt, i) == 42 # *
    count = -1
    explicit = 1
    i = i + 1
  elsif i < fmt.length && __ld8(fmt, i) >= 48 && __ld8(fmt, i) <= 57
    count = 0
    explicit = 1
    while i < fmt.length && __ld8(fmt, i) >= 48 && __ld8(fmt, i) <= 57
      count = count * 10 + (__ld8(fmt, i) - 48)
      i = i + 1
    end
  end
  [lp, ms, me, count, i, explicit]
end

def __pack_int_size(letter, mods)
  return 1 if letter == "c" || letter == "C"
  return 2 if letter == "s" || letter == "S" || letter == "n" || letter == "v"
  return 8 if letter == "q" || letter == "Q" || letter == "j" || letter == "J"
  return 8 if (letter == "l" || letter == "L") && (__str_include_p(mods, "_") || __str_include_p(mods, "!"))
  4
end

def __pack_big_endian_p(letter, mods)
  return true if letter == "n" || letter == "N"
  return false if letter == "v" || letter == "V"
  __str_include_p(mods, ">")
end

# an integer's low `size` bytes
def __pack_int_bytes(v, size, big)
  out = ""
  i = 0
  while i < size
    shift = big ? (size - 1 - i) * 8 : i * 8
    out = out + ((v >> shift) & 255).chr
    i = i + 1
  end
  out
end

def __pack_base64(s)
  tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  out = ""
  i = 0
  while i < s.length
    b0 = __ld8(s, i)
    b1 = i + 1 < s.length ? __ld8(s, i + 1) : 0
    b2 = i + 2 < s.length ? __ld8(s, i + 2) : 0
    out = out + tbl[b0 >> 2] + tbl[((b0 & 3) << 4) | (b1 >> 4)]
    out = out + (i + 1 < s.length ? tbl[((b1 & 15) << 2) | (b2 >> 6)] : "=")
    out = out + (i + 2 < s.length ? tbl[b2 & 63] : "=")
    i = i + 3
  end
  out
end

def __pack_m(s, count)
  return __pack_base64(s) if count == 0 # "m0": no line breaks
  per = count <= 2 || count == -1 ? 45 : (count / 3) * 3
  out = ""
  i = 0
  while i < s.length
    chunk = s[i, per]
    out = out + __pack_base64(chunk) + "\n"
    i = i + per
  end
  out
end

def __pack_uu(s)
  out = ""
  i = 0
  while i < s.length
    chunk = s[i, 45]
    out = out + (32 + chunk.length).chr
    j = 0
    while j < chunk.length
      b0 = __ld8(chunk, j)
      b1 = j + 1 < chunk.length ? __ld8(chunk, j + 1) : 0
      b2 = j + 2 < chunk.length ? __ld8(chunk, j + 2) : 0
      out = out + __uu_char(b0 >> 2) + __uu_char(((b0 & 3) << 4) | (b1 >> 4)) + __uu_char(((b1 & 15) << 2) | (b2 >> 6)) + __uu_char(b2 & 63)
      j = j + 3
    end
    out = out + "\n"
    i = i + 45
  end
  out
end
def __uu_char(v) = v == 0 ? "`" : (32 + v).chr

def __pack_hex_digit(c)
  return c - 48 if c >= 48 && c <= 57
  return c - 87 if c >= 97 && c <= 102
  return c - 55 if c >= 65 && c <= 70
  c & 15 # Ruby takes the low bits of other characters
end

def __arr_pack(a, fmt)
  out = ""
  ai = 0
  i = 0
  d = __pack_next(fmt, i)
  while d
    letter = fmt[d[0]]; mods = fmt[d[1], d[2] - d[1]]; count = d[3]; i = d[4]; explicit = d[5]
    if letter == "a" || letter == "A" || letter == "Z"
      raise(ArgumentError, "too few arguments") if ai >= a.length
      s = __dyn_to_s(a[ai]); ai = ai + 1
      if count == -1
        out = out + s
        out = out + 0.chr if letter == "Z"
      else
        piece = s.length >= count ? s[0, count] : s
        pad = letter == "A" ? 32.chr : 0.chr
        k = piece.length
        while k < count
          piece = piece + pad
          k = k + 1
        end
        out = out + piece
      end
    elsif letter == "b" || letter == "B"
      raise(ArgumentError, "too few arguments") if ai >= a.length
      s = __dyn_to_s(a[ai]); ai = ai + 1
      n = count == -1 ? s.length : (count > s.length ? s.length : count)
      byte = 0; bits = 0; k = 0
      while k < n
        bit = __ld8(s, k) & 1
        byte = letter == "B" ? (byte | (bit << (7 - bits))) : (byte | (bit << bits))
        bits = bits + 1
        if bits == 8
          out = out + byte.chr; byte = 0; bits = 0
        end
        k = k + 1
      end
      out = out + byte.chr if bits > 0
    elsif letter == "h" || letter == "H"
      raise(ArgumentError, "too few arguments") if ai >= a.length
      s = __dyn_to_s(a[ai]); ai = ai + 1
      n = count == -1 ? s.length : (count > s.length ? s.length : count)
      byte = 0; half = 0; k = 0
      while k < n
        v = __pack_hex_digit(__ld8(s, k))
        byte = letter == "H" ? (half == 0 ? v << 4 : byte | v) : (half == 0 ? v : byte | (v << 4))
        half = half + 1
        if half == 2
          out = out + byte.chr; byte = 0; half = 0
        end
        k = k + 1
      end
      out = out + byte.chr if half > 0
    elsif letter == "c" || letter == "C" || letter == "s" || letter == "S" || letter == "l" || letter == "L" || letter == "q" || letter == "Q" || letter == "n" || letter == "N" || letter == "v" || letter == "V" || letter == "j" || letter == "J"
      size = __pack_int_size(letter, mods)
      big = __pack_big_endian_p(letter, mods)
      n = count == -1 ? a.length - ai : count
      k = 0
      while k < n
        raise(ArgumentError, "too few arguments") if ai >= a.length
        v = a[ai]
        raise(TypeError, "no implicit conversion of nil into Integer") if __tag(v) == 0
        out = out + __pack_int_bytes(__dyn_to_int(v), size, big)
        ai = ai + 1
        k = k + 1
      end
    elsif letter == "U"
      n = count == -1 ? a.length - ai : count
      k = 0
      while k < n
        raise(ArgumentError, "too few arguments") if ai >= a.length
        cp = __dyn_to_int(a[ai]); ai = ai + 1
        raise(RangeError, "pack(U): value out of range") if cp < 0
        out = out + __utf8_encode(cp)
        k = k + 1
      end
    elsif letter == "w"
      n = count == -1 ? a.length - ai : count
      k = 0
      while k < n
        raise(ArgumentError, "too few arguments") if ai >= a.length
        v = __dyn_to_int(a[ai]); ai = ai + 1
        raise(ArgumentError, "can't compress negative numbers") if v < 0
        piece = (v & 127).chr
        v = v >> 7
        while v > 0
          piece = (128 | (v & 127)).chr + piece
          v = v >> 7
        end
        out = out + piece
        k = k + 1
      end
    elsif letter == "m"
      raise(ArgumentError, "too few arguments") if ai >= a.length
      s = __dyn_to_s(a[ai]); ai = ai + 1
      out = out + __pack_m(s, explicit == 1 ? count : 45)
    elsif letter == "u"
      raise(ArgumentError, "too few arguments") if ai >= a.length
      s = __dyn_to_s(a[ai]); ai = ai + 1
      out = out + __pack_uu(s)
    elsif letter == "M"
      raise(ArgumentError, "too few arguments") if ai >= a.length
      s = __dyn_to_s(a[ai]); ai = ai + 1
      out = out + __pack_qp(s, explicit == 1 && count > 1 ? count : 72)
    elsif letter == "x"
      n = count == -1 ? 0 : count
      k = 0
      while k < n
        out = out + 0.chr
        k = k + 1
      end
    elsif letter == "X"
      n = count == -1 ? 0 : count
      raise(ArgumentError, "X outside of string") if n > out.length
      out = out[0, out.length - n]
    elsif letter == "@"
      n = count == -1 ? 0 : count
      if n <= out.length
        out = out[0, n]
      else
        out = out + 0.chr while out.length < n
      end
    elsif letter == "%"
      raise(ArgumentError, "% is not supported")
    else
      raise(ArgumentError, "unknown pack directive '" + letter + "'")
    end
    d = __pack_next(fmt, i)
  end
  out
end

# the integer in s[at, size] (signed when `signed`)
def __unpack_int(s, at, size, big, signed)
  v = 0
  i = 0
  while i < size
    b = __ld8(s, at + i)
    shift = big ? (size - 1 - i) * 8 : i * 8
    v = v | (b << shift)
    i = i + 1
  end
  v = v - (1 << (size * 8)) if signed && size < 8 && v >= (1 << (size * 8 - 1))
  v
end

def __unpack_base64_val(c)
  return c - 65 if c >= 65 && c <= 90
  return c - 71 if c >= 97 && c <= 122
  return c + 4 if c >= 48 && c <= 57
  return 62 if c == 43
  return 63 if c == 47
  -1
end

def __unpack_m(s)
  out = ""
  acc = 0; bits = 0; i = 0
  while i < s.length
    v = __unpack_base64_val(__ld8(s, i))
    i = i + 1
    next if v < 0
    acc = (acc << 6) | v
    bits = bits + 6
    if bits >= 8
      bits = bits - 8
      out = out + ((acc >> bits) & 255).chr
    end
  end
  out
end

def __unpack_uu(s)
  out = ""
  i = 0
  while i < s.length
    len = (__ld8(s, i) - 32) & 63
    i = i + 1
    acc = 0; bits = 0; got = 0
    while got < len && i < s.length && __ld8(s, i) != 10
      v = (__ld8(s, i) - 32) & 63
      i = i + 1
      acc = (acc << 6) | v
      bits = bits + 6
      if bits >= 8
        bits = bits - 8
        if got < len
          out = out + ((acc >> bits) & 255).chr
          got = got + 1
        end
      end
    end
    i = i + 1 while i < s.length && __ld8(s, i) != 10
    i = i + 1
  end
  out
end

def __str_unpack(s, fmt)
  out = []
  at = 0
  i = 0
  d = __pack_next(fmt, i)
  while d
    letter = fmt[d[0]]; mods = fmt[d[1], d[2] - d[1]]; count = d[3]; i = d[4]
    if letter == "a" || letter == "A" || letter == "Z"
      n = count == -1 ? s.length - at : count
      n = s.length - at if at + n > s.length
      piece = s[at, n]
      if letter == "A"
        piece = piece[0, piece.length - 1] while piece.length > 0 && (__ld8(piece, piece.length - 1) == 32 || __ld8(piece, piece.length - 1) == 0)
      elsif letter == "Z"
        z = __str_index(piece, 0.chr)
        if z >= 0
          piece = piece[0, z]
          n = count == -1 ? z + 1 : n
        end
      end
      out.push(__box_str(piece))
      at = at + n
    elsif letter == "b" || letter == "B"
      n = count == -1 ? (s.length - at) * 8 : count
      n = (s.length - at) * 8 if n > (s.length - at) * 8
      bits = ""
      k = 0
      while k < n
        byte = __ld8(s, at + k / 8)
        bit = letter == "B" ? (byte >> (7 - k % 8)) & 1 : (byte >> (k % 8)) & 1
        bits = bits + (48 + bit).chr
        k = k + 1
      end
      out.push(__box_str(bits))
      at = at + (n + 7) / 8
    elsif letter == "h" || letter == "H"
      n = count == -1 ? (s.length - at) * 2 : count
      n = (s.length - at) * 2 if n > (s.length - at) * 2
      hex = ""
      k = 0
      while k < n
        byte = __ld8(s, at + k / 2)
        v = letter == "H" ? (k % 2 == 0 ? byte >> 4 : byte & 15) : (k % 2 == 0 ? byte & 15 : byte >> 4)
        hex = hex + "0123456789abcdef"[v]
        k = k + 1
      end
      out.push(__box_str(hex))
      at = at + (n + 1) / 2
    elsif letter == "c" || letter == "C" || letter == "s" || letter == "S" || letter == "l" || letter == "L" || letter == "q" || letter == "Q" || letter == "n" || letter == "N" || letter == "v" || letter == "V" || letter == "j" || letter == "J"
      size = __pack_int_size(letter, mods)
      big = __pack_big_endian_p(letter, mods)
      signed = letter == "c" || letter == "s" || letter == "l" || letter == "q" || letter == "j"
      n = count == -1 ? (s.length - at) / size : count
      k = 0
      while k < n
        if at + size > s.length
          out.push(nil)
        else
          out.push(__box_int(__unpack_int(s, at, size, big, signed)))
          at = at + size
        end
        k = k + 1
      end
    elsif letter == "U"
      n = count == -1 ? s.length : count
      k = 0
      while k < n && at < s.length
        len = __utf8_len(__ld8(s, at))
        cp = __str_ord(s[at, len])
        out.push(__box_int(cp))
        at = at + len
        k = k + 1
      end
    elsif letter == "w"
      n = count == -1 ? s.length : count
      k = 0
      while k < n && at < s.length
        v = 0
        while at < s.length
          b = __ld8(s, at)
          at = at + 1
          v = (v << 7) | (b & 127)
          break if b < 128
        end
        out.push(__box_int(v))
        k = k + 1
      end
    elsif letter == "m"
      out.push(__box_str(__unpack_m(s[at, s.length - at])))
      at = s.length
    elsif letter == "u"
      out.push(__box_str(__unpack_uu(s[at, s.length - at])))
      at = s.length
    elsif letter == "M"
      out.push(__box_str(__unpack_qp(s[at, s.length - at])))
      at = s.length
    elsif letter == "x"
      n = count == -1 ? s.length - at : count
      raise(ArgumentError, "x outside of string") if at + n > s.length
      at = at + n
    elsif letter == "X"
      n = count == -1 ? 0 : count
      raise(ArgumentError, "X outside of string") if n > at
      at = at - n
    elsif letter == "@"
      n = count == -1 ? 0 : count
      raise(ArgumentError, "@ outside of string") if n > s.length
      at = n
    else
      raise(ArgumentError, "unknown unpack directive '" + letter + "'")
    end
    d = __pack_next(fmt, i)
  end
  out
end

def __str_unpack1(s, fmt)
  r = __str_unpack(s, fmt)
  r.length > 0 ? r[0] : nil
end

# a typed array's elements boxed into a :dyn array (Types gives the element kind: each store boxes by its own type)
def __arr_to_dyn(a)
  out = []
  i = 0
  while i < a.length
    out.push(__to_dyn(a[i]))
    i = i + 1
  end
  out
end

# quoted-printable: bytes outside printable ASCII (and = and trailing space) as =XX, soft breaks "=\n" before `width`
def __pack_qp(s, width)
  out = ""
  line = ""
  i = 0
  while i < s.length
    c = __ld8(s, i)
    if c == 10
      line = line[0, line.length - 1] + "=20" if line.length > 0 && __ld8(line, line.length - 1) == 32
      line = line[0, line.length - 1] + "=09" if line.length > 0 && __ld8(line, line.length - 1) == 9
      out = out + line + "\n"
      line = ""
    else
      piece = (c == 61 || c < 32 || c > 126) && c != 9 && c != 32 ? "=" + __hex2(c) : s[i, 1]
      if line.length + piece.length > width + 1
        out = out + line + "=\n"
        line = ""
      end
      line = line + piece
    end
    i = i + 1
  end
  out = out + line + "=\n" if line.length > 0
  out
end

def __unpack_qp(s)
  out = ""
  i = 0
  while i < s.length
    c = __ld8(s, i)
    if c == 61 && i + 1 < s.length && __ld8(s, i + 1) == 10 then i = i + 2
    elsif c == 61 && i + 2 < s.length && __ld8(s, i + 1) == 13 && __ld8(s, i + 2) == 10 then i = i + 3
    elsif c == 61 && i + 2 < s.length
      out = out + ((__pack_hex_digit(__ld8(s, i + 1)) << 4) | __pack_hex_digit(__ld8(s, i + 2))).chr
      i = i + 3
    else
      out = out + s[i, 1]
      i = i + 1
    end
  end
  out
end
