# SSA passes.
module Indus
  module Passes
    # phi whose args are all itself or one value v -> v
    def self.trivial_phis(f)
      loop do
        changed = false
        used = {}
        f.all.each { |i| (i.op == :phi ? i.args.map(&:last) : i.args).each { used[_1] = true if _1.is_a?(Inst) } }
        f.blocks.each do |b|
          b.phis.dup.each do |p|
            unless used[p] # dead phi (e.g. the value of an if whose arms are statements)
              b.phis.delete(p); changed = true; next
            end
            others = p.args.map(&:last).reject { _1 == p }.uniq
            next unless others.size == 1
            f.replace_uses(p, others[0]); b.phis.delete(p); changed = true
          end
        end
        break unless changed
      end
    end

    def self.sink_returns(f)
      f.blocks.dup.each do |b|
        r = b.term
        next unless r&.op == :ret && (p = r.args[0]).op == :phi && p.block == b && b.insts.size == 1 && b.phis == [p]
        p.args.each { |(pred, v)| pred.insts.pop; pred << Inst.new(:ret, [v]) }
        f.blocks.delete(b)
      end
    end

    def self.accumulate(f)
      rets = f.blocks.map(&:term).select { _1&.op == :ret }
      tail = rets.find { |r| (v = r.args[0]).op == :add && v.args.any? { |a| a.op == :call && a.args[0] == f } }
      return false unless tail
      return false if f.rtype == :float
      add = tail.args[0]
      self_call = add.args.reverse.find { |a| a.op == :call && a.args[0] == f }
      other = add.args.find { _1 != self_call }
      return false if f.blocks.any? { |b| b.phis.any? } # keep it simple: no existing loops

      header = Block.new(:header); old_entry = f.entry; entry = Block.new(:entry)
      f.blocks.insert(1, header); f.blocks.unshift(entry)
      zero = entry << Inst.new(:const, [0]); zero.ty = :int; entry << Inst.new(:br, [header])
      header << Inst.new(:br, [old_entry]); old_entry.name = :body
      param_phis = f.params.each_with_index.map { |_, k| ph = header.phi; ph.ty = f.ptypes[k]; ph }
      acc = header.phi; acc.ty = f.rtype
      param_phis.each_with_index { |p, i| p.args << [entry, f.params[i]] }; acc.args << [entry, zero]
      rewrite = f.params.zip(param_phis).to_h
      f.blocks.each do |b|
        b.phis.each { |p| p.args.map! { |(bb, v)| [bb, rewrite.fetch(v, v)] } unless b == header }
        b.insts.each { |i| i.args.map! { |a| rewrite.fetch(a, a) } }
      end
      tb = tail.block
      tb.insts.delete(add); tb.insts.delete(self_call); tb.insts.delete(tail)
      acc2 = tb << Inst.new(:add, [acc, other]); acc2.ty = f.rtype; tb << Inst.new(:br, [header])
      param_phis.each_with_index { |p, i| p.args << [tb, self_call.args[i + 1]] }; acc.args << [tb, acc2]
      (rets - [tail]).each do |r|
        r.block.insts.delete(r)
        sum = r.block << Inst.new(:add, [r.args[0], acc]); sum.ty = f.rtype; r.block << Inst.new(:ret, [sum])
      end
      true
    end

    def self.run(f)
      trivial_phis(f)
      sink_returns(f)
      accumulate(f)
    end
  end
end
