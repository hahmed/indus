# Division by a constant as a multiply-high (Hacker's Delight 10-1, signed
# 64-bit). q = (mulh(x, M) [+ x if M < 0]) >> s, then + (x >>> 63) to
# truncate toward zero. Ruby's floor semantics are fixed up after.
module Indus
  module Magic
    def self.for(d)
      raise ArgumentError, "d >= 2" unless d >= 2
      two63 = 1 << 63
      ad = d
      t = two63
      anc = t - 1 - t % ad
      p = 63
      q1 = two63 / anc; r1 = two63 - q1 * anc
      q2 = two63 / ad;  r2 = two63 - q2 * ad
      loop do
        p += 1
        q1 *= 2; r1 *= 2
        if r1 >= anc then q1 += 1; r1 -= anc end
        q2 *= 2; r2 *= 2
        if r2 >= ad then q2 += 1; r2 -= ad end
        delta = ad - r2
        break unless q1 < delta || (q1 == delta && r1 == 0)
      end
      m = q2 + 1
      m -= 1 << 64 if m >= two63 # as a signed multiplier
      [m, p - 64]
    end

    # reference evaluation, mirrors the instruction sequence; for tests
    def self.div_trunc(x, d)
      m, s = self.for(d)
      hi = (x * m) >> 64            # smulh
      hi += x if m < 0
      q = hi >> s
      q + ((x >> 63) & 1)            # toward zero
    end
  end
end
