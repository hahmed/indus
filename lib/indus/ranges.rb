# frozen_string_literal: true

# Integer ranges, to drop overflow checks that cannot fire.
#
# Every `+ - *` on Integers traps on 64-bit overflow (Ruby would promote to Bignum, and the
# compiler promotes where it can prove growth, notes/38). The check is one `b.vs` per
# operation -- cheap, but it sits in every loop, and the loop counter of `while i < n` can
# never overflow. This pass computes a conservative interval per integer value and marks the
# operations whose result provably fits; codegen emits the plain instruction for those.
#
# The lattice is [lo, hi] with saturation at +-LIMIT (2^62): anything that reaches a
# saturated bound is "unknown" and keeps its check. Phis start at bottom and widen once --
# a loop-carried value that grows takes the saturated bound, so growth is never proved safe.
module Indus
  module Ranges
    LIMIT = 1 << 62
    UNKNOWN = [-LIMIT, LIMIT].freeze
    SAFE = (1 << 62) - 1 # a result inside +-2^62 cannot have overflowed a 64-bit add/sub/mul

    def self.run(f)
      r = {}                        # Inst -> [lo, hi]
      at = ->(v) { v.is_a?(Inst) ? (r[v] || UNKNOWN) : UNKNOWN }
      # the header compare of a loop bounds its counter: `while i < n` with n bounded
      2.times do                    # one pass to seed, one to use the bounds of phis
        f.blocks.each do |b|
          b.phis.each { |p| r[p] = phi_range(p, r, at) if p.ty == :int || p.ty == :int? }
          b.insts.each do |i|
            next unless i.ty == :int || i.ty == :int?
            r[i] = range_of(i, at)
          end
        end
      end
      f.all.each do |i|
        if %i[add sub mul].include?(i.op) && (i.ty == :int || i.ty == :int?)
          lo, hi = range_of(i, at, exact: true)
          i.nocheck = true if lo > -LIMIT && hi < LIMIT
        end
        # a non-negative dividend needs no floor fix-up: Ruby's / and % agree with truncation there
        i.nonneg = true if %i[div mod].include?(i.op) && at.(i.args[0])[0] >= 0 && at.(i.args[1])[0] > 0
      end
    end

    MAXSTEP = 1 << 20

    # A loop counter: a header phi whose back edges are `phi + k` / `phi - k` with a small
    # constant k, and whose header compares it against a bounded value. Inside the loop the
    # test held, so the phi is within the bound; the value that leaves the loop is one step
    # past it. Anything else keeps the saturated range.
    def self.phi_range(p, r, at)
      vals = p.args.map { |(_, v)| at.(v) }
      return UNKNOWN if vals.empty?
      entry = p.args.reject { |(_, v)| induction_step(p, v) }.map { |(_, v)| at.(v) }
      steps = p.args.filter_map { |(_, v)| induction_step(p, v) }
      if steps.any? && entry.any? && entry.none? { _1 == UNKNOWN } && (bound = header_bound(p))
        up = steps.all?(&:positive?)
        down = steps.all?(&:negative?)
        step = steps.map(&:abs).max
        lo = up ? entry.map(&:first).min : [entry.map(&:first).min, bound[0]].min - step
        hi = down ? entry.map(&:last).max : [entry.map(&:last).max, bound[1]].max + step
        return clamp([lo, hi])
      end
      return UNKNOWN if vals.any? { _1 == UNKNOWN }
      clamp([vals.map(&:first).min, vals.map(&:last).max])
    end

    # v is `p + k` or `p - k` with |k| <= MAXSTEP: the step, or nil
    def self.induction_step(p, v)
      return nil unless v.is_a?(Inst) && %i[add sub].include?(v.op)
      k = v.args[1]
      return nil unless v.args[0].equal?(p) && k.is_a?(Inst) && k.op == :const && k.args[0].is_a?(Integer) && k.args[0].abs <= MAXSTEP
      v.op == :add ? k.args[0] : -k.args[0]
    end

    # the bound the header's comparison puts on p, when the other side is itself bounded
    def self.header_bound(p)
      t = p.block.term
      return nil unless t && t.op == :condbr && t.args[0].is_a?(Inst) && t.args[0].op == :cmp
      c = t.args[0]
      other = c.args[0].equal?(p) ? c.args[1] : (c.args[1].equal?(p) ? c.args[0] : nil)
      return nil unless other
      b = other.is_a?(Inst) ? bound_of_operand(other) : nil
      return nil if b.nil? || b == UNKNOWN
      b
    end

    def self.bound_of_operand(v)
      case v.op
      when :const then v.args[0].is_a?(Integer) ? [v.args[0], v.args[0]] : nil
      when :alen, :hcap then [0, 1 << 40]
      when :param then nil
      else nil
      end
    end

    def self.clamp(iv)
      lo, hi = iv
      [[lo, -LIMIT].max, [hi, LIMIT].min]
    end

    def self.range_of(i, at, exact: false)
      case i.op
      when :const then v = i.args[0]; v.is_a?(Integer) ? clamp([v, v]) : UNKNOWN
      when :alen, :hcap then [0, 1 << 40]          # a container's length: memory bounds it
      when :dyn_tag then [0, 15]
      when :cmp, :isa, :is_dyn, :is_sym, :is_arr then [0, 1]
      when :add, :sub, :mul
        a, b = at.(i.args[0]), at.(i.args[1])
        return UNKNOWN if a == UNKNOWN || b == UNKNOWN
        combos = case i.op
                 when :add then [a[0] + b[0], a[1] + b[1]]
                 when :sub then [a[0] - b[1], a[1] - b[0]]
                 else
                   ps = [a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1]]
                   [ps.min, ps.max]
                 end
        exact ? combos : clamp(combos)
      when :and
        a, b = at.(i.args[0]), at.(i.args[1])
        a[0] >= 0 && b[0] >= 0 ? [0, [a[1], b[1]].min] : UNKNOWN # masking non-negatives
      when :mod
        b = at.(i.args[1])
        b[0] > 0 ? [-(b[1] - 1), b[1] - 1] : UNKNOWN
      when :div
        a, b = at.(i.args[0]), at.(i.args[1])
        b[0] > 0 && a != UNKNOWN ? clamp([a[0] / b[0], a[1] / b[0]]) : UNKNOWN
      when :lsr, :shr
        a = at.(i.args[0])
        a[0] >= 0 ? [0, a[1]] : UNKNOWN
      when :phi then UNKNOWN # filled by phi_range
      else UNKNOWN
      end
    end
  end
end
