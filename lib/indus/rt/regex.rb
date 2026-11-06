# The regexp matcher: a backtracking VM over the program lib/indus/regex.rb compiles at
# compile time (op list there). Bytes, not characters. Captures are an int array of
# 2 * (ngroups + 1) positions, -1 when unset; group 0 is the whole match.
#
# A match attempt from one start position is iterative: the backtrack stack holds
# [pc, pos, saved-capture-snapshot-index] triples. Snapshots of the capture array are
# taken only at splits inside groups (cheap for the common patterns).

REGEX_OP_CHAR = 0
REGEX_OP_ANY = 1
REGEX_OP_CLASS = 2
REGEX_OP_SPLIT = 3
REGEX_OP_JMP = 4
REGEX_OP_SAVE = 5
REGEX_OP_MATCH = 6
REGEX_OP_BOL = 7
REGEX_OP_EOL = 8
REGEX_OP_BOS = 9
REGEX_OP_EOS = 10
REGEX_OP_WORDB = 11
REGEX_OP_NWORDB = 12
REGEX_OP_EOSNL = 13
REGEX_OP_BACKREF = 14

def __re_word_byte(b) = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95

# does the class at pc match byte b? returns the pc just past the class
def __re_class_match(prog, pc, b, out)
  n = prog[pc + 1]
  neg = prog[pc + 2]
  i = 0
  hit = false
  while i < n
    lo = prog[pc + 3 + i * 2]
    hi = prog[pc + 4 + i * 2]
    hit = true if b >= lo && b <= hi
    i = i + 1
  end
  out[0] = (neg == 1) ? !hit : hit
  pc + 3 + n * 2
end

# one attempt at position start. caps is filled on success; returns true/false
def __re_try(prog, s, start, caps, ncap)
  len = s.length
  i = 0
  while i < ncap
    caps[i] = -1
    i = i + 1
  end
  # backtrack stack: pc, pos, and a copy of caps (flat)
  stack_pc = []
  stack_pos = []
  stack_caps = []
  pc = 0
  pos = start
  hit = [false]
  while true
    op = prog[pc]
    ok = true
    if op == REGEX_OP_CHAR
      if pos < len && __byte_at(s, pos) == prog[pc + 1]
        pos = pos + 1
        pc = pc + 2
      else
        ok = false
      end
    elsif op == REGEX_OP_ANY
      if pos < len && __byte_at(s, pos) != 10
        pos = pos + 1
        pc = pc + 1
      else
        ok = false
      end
    elsif op == REGEX_OP_CLASS
      if pos < len
        npc = __re_class_match(prog, pc, __byte_at(s, pos), hit)
        if hit[0]
          pos = pos + 1
          pc = npc
        else
          ok = false
        end
      else
        ok = false
      end
    elsif op == REGEX_OP_SPLIT
      # push the second alternative, follow the first
      stack_pc.push(pc + prog[pc + 2])
      stack_pos.push(pos)
      j = 0
      while j < ncap
        stack_caps.push(caps[j])
        j = j + 1
      end
      pc = pc + prog[pc + 1]
    elsif op == REGEX_OP_JMP
      pc = pc + prog[pc + 1]
    elsif op == REGEX_OP_SAVE
      caps[prog[pc + 1]] = pos
      pc = pc + 2
    elsif op == REGEX_OP_MATCH
      caps[0] = start
      caps[1] = pos
      return true
    elsif op == REGEX_OP_BOL
      if pos == 0 || __byte_at(s, pos - 1) == 10 then pc = pc + 1 else ok = false end
    elsif op == REGEX_OP_EOL
      if pos == len || __byte_at(s, pos) == 10 then pc = pc + 1 else ok = false end
    elsif op == REGEX_OP_BOS
      if pos == 0 then pc = pc + 1 else ok = false end
    elsif op == REGEX_OP_EOS
      if pos == len then pc = pc + 1 else ok = false end
    elsif op == REGEX_OP_EOSNL
      if pos == len || (pos == len - 1 && __byte_at(s, pos) == 10) then pc = pc + 1 else ok = false end
    elsif op == REGEX_OP_WORDB || op == REGEX_OP_NWORDB
      before = pos > 0 && __re_word_byte(__byte_at(s, pos - 1))
      after = pos < len && __re_word_byte(__byte_at(s, pos))
      at_b = before != after
      at_b = !at_b if op == REGEX_OP_NWORDB
      if at_b then pc = pc + 1 else ok = false end
    elsif op == REGEX_OP_BACKREF
      g = prog[pc + 1]
      gs = caps[g * 2]
      ge = caps[g * 2 + 1]
      if gs < 0 || ge < 0
        ok = false
      else
        glen = ge - gs
        if pos + glen <= len && __bytes_equal(s, gs, s, pos, glen)
          pos = pos + glen
          pc = pc + 2
        else
          ok = false
        end
      end
    else
      __trap
    end
    unless ok
      return false if stack_pc.length == 0
      pc = stack_pc.pop
      pos = stack_pos.pop
      j = ncap - 1
      while j >= 0
        caps[j] = stack_caps.pop
        j = j - 1
      end
    end
  end
  false
end

def __bytes_equal(a, ai, b, bi, n)
  k = 0
  while k < n
    return false if __byte_at(a, ai + k) != __byte_at(b, bi + k)
    k = k + 1
  end
  true
end

# search from `from`: the first position where the program matches. caps filled; returns
# the match start, or -1
def __re_search(prog, s, from, caps, ncap)
  start = from
  len = s.length
  while start <= len
    return start if __re_try(prog, s, start, caps, ncap)
    start = start + 1
  end
  -1
end

# ---- the String methods, over a program and its group count --------------------------

def __re_match_p(prog, ncap, s) = __re_search(prog, s, 0, __re_caps(ncap), ncap) >= 0

def __re_caps(ncap)
  c = []
  i = 0
  while i < ncap
    c.push(-1)
    i = i + 1
  end
  c
end

# =~ : the match position or nil; the captures land in the globals $~ reads
def __re_index(prog, ncap, s)
  caps = __re_caps(ncap)
  at = __re_search(prog, s, 0, caps, ncap)
  return nil if at < 0
  $__re_last_caps = caps
  $__re_last_str = s
  at
end

# match: an array of the groups' strings (nil for an unset group), or nil
def __re_match(prog, ncap, s)
  caps = __re_caps(ncap)
  at = __re_search(prog, s, 0, caps, ncap)
  return nil if at < 0
  $__re_last_caps = caps
  $__re_last_str = s
  __re_groups(s, caps, ncap)
end

def __re_groups(s, caps, ncap)
  out = []
  g = 0
  while g * 2 < ncap
    gs = caps[g * 2]
    ge = caps[g * 2 + 1]
    out.push(gs < 0 ? nil : s[gs, ge - gs])
    g = g + 1
  end
  out
end

# $1..$9 after the last =~ / match
def __re_group(n)
  caps = $__re_last_caps
  return nil if caps.nil? || n * 2 + 1 >= caps.length
  gs = caps[n * 2]
  ge = caps[n * 2 + 1]
  return nil if gs < 0
  $__re_last_str[gs, ge - gs]
end

# scan without groups: every non-overlapping whole match
def __re_scan(prog, ncap, s)
  out = []
  from = 0
  caps = __re_caps(ncap)
  while from <= s.length
    at = __re_search(prog, s, from, caps, ncap)
    break if at < 0
    me = caps[1]
    out.push(s[at, me - at])
    from = me > at ? me : at + 1 # an empty match advances by one
  end
  out
end

# scan with groups: the groups array per match
def __re_scan_groups(prog, ncap, s)
  out = []
  from = 0
  caps = __re_caps(ncap)
  while from <= s.length
    at = __re_search(prog, s, from, caps, ncap)
    break if at < 0
    me = caps[1]
    gs = __re_groups(s, caps, ncap)
    gs.shift
    out.push(gs)
    from = me > at ? me : at + 1
  end
  out
end

# the replacement with \1..\9 and \0 expanded
def __re_expand(rep, s, caps, ncap)
  return rep unless rep.include?("\\")
  out = +""
  i = 0
  while i < rep.length
    c = rep[i]
    if c == "\\" && i + 1 < rep.length && rep[i + 1] >= "0" && rep[i + 1] <= "9"
      g = rep[i + 1].ord - 48
      if g * 2 + 1 < ncap && caps[g * 2] >= 0
        out << s[caps[g * 2], caps[g * 2 + 1] - caps[g * 2]]
      end
      i = i + 2
    else
      out << c
      i = i + 1
    end
  end
  out
end

def __re_sub(prog, ncap, s, rep)
  caps = __re_caps(ncap)
  at = __re_search(prog, s, 0, caps, ncap)
  return s.dup if at < 0
  s[0, at] + __re_expand(rep, s, caps, ncap) + s[caps[1], s.length - caps[1]]
end

def __re_gsub(prog, ncap, s, rep)
  out = +""
  from = 0
  caps = __re_caps(ncap)
  while from <= s.length
    at = __re_search(prog, s, from, caps, ncap)
    break if at < 0
    me = caps[1]
    out << s[from, at - from]
    out << __re_expand(rep, s, caps, ncap)
    if me > at
      from = me
    else
      out << s[at, 1] if at < s.length # an empty match: keep the byte, step over it
      from = at + 1
    end
  end
  out << s[from, s.length - from] if from <= s.length
  out
end

def __re_split(prog, ncap, s)
  out = []
  from = 0
  caps = __re_caps(ncap)
  while from < s.length
    at = __re_search(prog, s, from, caps, ncap)
    break if at < 0
    me = caps[1]
    if me == at # empty match: split between bytes
      out.push(s[from, at + 1 - from]) if at + 1 <= s.length
      from = at + 1
    else
      out.push(s[from, at - from])
      from = me
    end
  end
  out.push(s[from, s.length - from]) if from < s.length
  # Ruby drops trailing empty strings
  out.pop while out.length > 0 && out[out.length - 1] == ""
  out
end

# a Regexp literal: the compiled program and its capture count (2 * (groups + 1))
class Regexp
  attr_reader :prog, :ncap, :source
  def initialize(prog, ncap, source)
    @prog = prog
    @ncap = ncap
    @source = source
  end
  def match?(s) = __re_match_p(@prog, @ncap, s)
  def match(s) = __re_match(@prog, @ncap, s)
  def =~(s) = __re_index(@prog, @ncap, s)
  def to_s = "(?-mix:" + @source + ")"
  def inspect = "/" + @source + "/"
end

def __str_match_re(s, re) = __re_match(re.prog, re.ncap, s)
def __str_match_p_re(s, re) = __re_match_p(re.prog, re.ncap, s)
def __str_index_re(s, re) = __re_index(re.prog, re.ncap, s)
def __str_scan_re(s, re) = __re_scan(re.prog, re.ncap, s)
def __str_scan_groups_re(s, re) = __re_scan_groups(re.prog, re.ncap, s)
def __str_sub_re(s, re, rep) = __re_sub(re.prog, re.ncap, s, rep)
def __str_gsub_re(s, re, rep) = __re_gsub(re.prog, re.ncap, s, rep)
def __str_split_re(s, re) = __re_split(re.prog, re.ncap, s)

# the program's words from their byte form (little-endian, 4 bytes, two's complement)
def __re_decode(bytes)
  out = []
  i = 0
  while i + 3 < bytes.length
    w = __byte_at(bytes, i) + __byte_at(bytes, i + 1) * 256 + __byte_at(bytes, i + 2) * 65536 + __byte_at(bytes, i + 3) * 16777216
    w = w - 4294967296 if w >= 2147483648
    out.push(w)
    i = i + 4
  end
  out
end

# gsub with a block: the block gets each match string, its result replaces it
def __re_gsub_blk(prog, ncap, s, blk)
  out = +""
  from = 0
  caps = __re_caps(ncap)
  while from <= s.length
    at = __re_search(prog, s, from, caps, ncap)
    break if at < 0
    me = caps[1]
    out << s[from, at - from]
    $__re_last_caps = caps
    $__re_last_str = s
    out << blk.call(s[at, me - at])
    if me > at
      from = me
    else
      out << s[at, 1] if at < s.length
      from = at + 1
    end
  end
  out << s[from, s.length - from] if from <= s.length
  out
end
def __str_gsub_blk_re(s, re, blk) = __re_gsub_blk(re.prog, re.ncap, s, blk)
def __re_sub_blk(prog, ncap, s, blk)
  caps = __re_caps(ncap)
  at = __re_search(prog, s, 0, caps, ncap)
  return __sdup(s) if at < 0
  me = caps[1]
  $__re_last_caps = caps
  $__re_last_str = s
  s[0, at] + blk.call(s[at, me - at]) + s[me, s.length - me]
end
def __str_sub_blk_re(s, re, blk) = __re_sub_blk(re.prog, re.ncap, s, blk)
def __re_groups_array
  caps = $__re_last_caps
  return nil if caps.nil?
  __re_groups($__re_last_str, caps, caps.length)
end
