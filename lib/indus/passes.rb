# SSA passes.
module Indus
  module Passes
    # phi whose args are all itself or one value v -> v
    # functions no call reaches from main are dropped: the preludes carry every
    # String/Float/dyn helper, most of which a given program never uses (and
    # an unused helper has untyped params, which codegen cannot take). A
    # program with seams keeps everything: the resident compiler may call any.
    def self.prune(funcs)
      seams = funcs.any? { |f| f.all.any? { _1.op == :seam } }
      live = {}; work = funcs.select { |f| f.name == :main || f.name == :__gc_run || f.name == :__gc_keep } # the runtime enters the collector; codegen calls __gc_keep
      until work.empty?
        f = work.pop
        next if live[f]
        live[f] = true
        f.all.each do |i|
          case i.op
          when :call, :zcheck then work << i.args[0]
          when :pcall, :sendsw then i.args[0].each { |(_, kind, payload)| work << payload if kind == :call }
          when :dsend then i.args.each { |a| work << a if a.is_a?(Func) }
          when :setslot then work << i.args[1]
          end
          i.args.each { |a| work << a if a.is_a?(Func) } if i.op == :const || i.op == :lambda || i.op == :adrlbl
        end
      end
      # with seams, keep every typed function too: the resident compiler may call it later
      funcs.select { |f| live[f] || (seams && f.ptypes.none?(&:nil?)) }
    end

    # dead phis (the value of an if whose arms are statements) and phis of one value: gone.
    # Per round: one scan for uses, decide every phi, then one substitution pass.
    def self.trivial_phis(f)
      loop do
        all = f.all
        used = phi_liveness(all)
        subst = {}; removed = false
        f.blocks.each do |b|
          b.phis.reject! do |p|
            next (removed = true) unless used[p]
            others = p.args.map(&:last).reject { _1 == p }.uniq
            next false unless others.size == 1
            subst[p] = others[0]; removed = true
          end
        end
        break unless removed
        next if subst.empty?
        resolve = ->(v) { v = subst[v] while subst.key?(v); v }
        f.all.each { |i| i.op == :phi ? i.args.map! { |(bb, v)| [bb, resolve.(v)] } : i.args.map! { |a| a.is_a?(Inst) ? resolve.(a) : a } }
      end
    end

    # values with a use outside phis, plus everything those uses' phis read, transitively: a cycle of
    # phis that only feed each other (a loop variable nobody reads) is dead
    def self.phi_liveness(all)
      used = {}; work = []
      all.each { |i| next if i.op == :phi; i.args.each { |a| next unless a.is_a?(Inst); (used[a] = true; work << a) unless used[a] } }
      until work.empty?
        v = work.pop
        next unless v.op == :phi
        v.args.each { |(_, a)| next unless a.is_a?(Inst); (used[a] = true; work << a) unless used[a] }
      end
      used
    end

    # an integer constant used inside a loop that no instruction can take as an immediate (a compare
    # or add/sub operand over 4095, a multiplier) is materialised on every iteration: two instructions
    # for a large one. Move it to the loop's preheader; the allocator gives it a register (if it must
    # spill, the reload costs the same as the materialisation did). Only loops: a straight-line const
    # is cheaper where it is.
    IMM_USES = { cmp: [1], add: [1], sub: [1], shl: [1], shr: [1], aget: [1], aset: [1], ssub: [1, 2] }.freeze
    def self.hoist_consts(f)
      f.blocks.each do |h|
        next unless h.name.to_s.start_with?("head") && !h.phis.empty?
        pre = h.phis.first.args[0][0]
        latches = f.blocks.select { |b| b.succs.include?(h) && b != pre }
        next if latches.empty? || pre.succs != [h]
        body = Escape.loop_body(f, h, latches)
        # constants defined in the body, and constants from outside whose every use is in this body
        cands = body.keys.flat_map { |b| b.insts.select { |i| i.op == :const } }
        f.blocks.each { |b| next if body[b]; b.insts.each { |i| cands << i if i.op == :const } }
        cands.each do |i|
          next unless i.args[0].is_a?(Integer) && !i.hoisted
          next if (-65536..65535).cover?(i.args[0]) # one movz/movn where it is: hoisting would not pay for the register
          users = f.all.select { |u| u.args.include?(i) }
          next if users.empty? || users.any? { |u| !body[u.block] }
          # every use must want a register: an immediate-encodable use is free as it is
          next if users.any? { |u| (IMM_USES[u.op] || []).any? { |k| u.args[k] == i } && (0..4095).cover?(i.args[0]) }
          next if users.any? { |u| %i[mod div].include?(u.op) && u.args[1] == i } # divmod_const takes the constant itself
          next if users.any? { |u| %i[const puts_i print_i].include?(u.op) }
          i.block.insts.delete(i); i.block = pre; pre.insts.insert(pre.insts.index(pre.term), i); i.hoisted = true
        end
      end
    end

    def self.sink_returns(f)
      f.blocks.dup.each do |b|
        r = b.term
        next unless r&.op == :ret && (p = r.args[0]).op == :phi && p.block == b && b.insts.size == 1 && b.phis == [p]
        next unless p.args.all? { |(pred, _)| pred.term&.op == :br && pred.term.args[0] == b } # every predecessor jumps here unconditionally (a condbr edge cannot take the ret)
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
