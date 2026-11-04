# SSA peepholes on strings, after typing.
#
# 1. seq(ssub(s, i, 1), "c")  ->  seq_char(s, i, byte)
#    `template[i] == "{"` without allocating a one-character string.
# 2. scat(a, b)  ->  sappend(a, b)  when a is a fresh string (built here:
#    sconst/scat/sappend/ssub/itos, or a phi of such), every use of a only
#    reads it (never stored, passed, or returned -- so no alias exists), and
#    a is dead after this instruction (block liveness). `result = result + x`
#    becomes an in-place append: O(n) instead of O(n^2) per build.
module Indus
  module Peephole
    FRESH = %i[sconst scat sappend ssub itos sdup salloc chr].freeze
    READERS = %i[scat sappend seq seq_char alen ssub puts_str phi].freeze # uses that do not alias the string

    def self.run(f)
      uses = Hash.new(0); users = Hash.new { |h, k| h[k] = [] }
      f.all.each { |i| (i.op == :phi ? i.args.map(&:last) : i.args).each { next unless _1.is_a?(Inst); uses[_1] += 1; users[_1] << i } }
      live_out = liveness(f)

      f.blocks.each do |b|
        b.insts.dup.each do |i|
          case i.op
          when :seq
            l, r = i.args
            sub, lit = [l, r].partition { _1.op == :ssub }.then { |(subs, rest)| [subs[0], rest[0]] }
            next unless sub && lit && lit.op == :sconst && lit.args[0].bytesize == 1 && uses[sub] == 1
            _, idx, len = sub.args
            next unless len.op == :const && len.args[0] == 1
            i.op = :seq_char; i.args = [sub.args[0], idx, lit.args[0].ord]
            b.insts.delete(sub) if sub.block == b
            b.insts.delete(lit) if lit.block == b && uses[lit] == 1
          when :scat
            a, _ = i.args
            next unless fresh?(a, {})
            next unless users[a].all? { |u| READERS.include?(u.op) && !(u.op == :sappend && u.args[1] == a) }
            later = b.insts[(b.insts.index(i) + 1)..].any? { |u| u.args.include?(a) }
            i.op = :sappend if !later && !live_out[b][a]
          end
        end
      end
    end

    # block-level liveness (same dataflow as RegAlloc, values only)
    def self.liveness(f)
      use = Hash.new { |h, k| h[k] = {} }; dfn = Hash.new { |h, k| h[k] = {} }
      f.blocks.each do |b|
        b.phis.each { dfn[b][_1] = true }
        b.insts.each { |i| i.args.each { |a| use[b][a] = true if a.is_a?(Inst) && !dfn[b][a] }; dfn[b][i] = true }
        b.succs.each { |s| s.phis.each { |p| p.args.each { |(pred, v)| use[b][v] = true if pred == b && v.is_a?(Inst) && !dfn[b][v] } } }
      end
      live_in = Hash.new { |h, k| h[k] = {} }; live_out = Hash.new { |h, k| h[k] = {} }
      loop do
        changed = false
        f.blocks.reverse_each do |b|
          out = {}
          b.succs.each do |s|
            live_in[s].each_key { |v| out[v] = true unless s.phis.include?(v) }
            s.phis.each { |p| p.args.each { |(pred, v)| out[v] = true if pred == b && v.is_a?(Inst) } }
          end
          inn = use[b].dup; out.each_key { |v| inn[v] = true unless dfn[b][v] }
          (live_in[b] = inn; live_out[b] = out; changed = true) if inn != live_in[b] || out != live_out[b]
        end
        break unless changed
      end
      live_out
    end

    def self.fresh?(v, seen)
      return false unless v.is_a?(Inst)
      return true if FRESH.include?(v.op)
      return false unless v.op == :phi
      return true if seen[v]
      seen[v] = true
      v.args.all? { |(_, x)| fresh?(x, seen) }
    end
  end
end
