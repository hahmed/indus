# SSA IR: values, blocks, functions.
module Indus
  class Inst
    attr_accessor :op, :args, :block, :reg, :cond, :slot, :shared, :ty
    attr_reader :id
    @@n = 0
    def initialize(op, args = [], cond = nil) = (@op, @args, @cond, @id = op, args, cond, @@n += 1)
    def term? = %i[br condbr ret].include?(op)
    def call? = %i[call mcall puts_i puts_s putc anew aset onew ipow].include?(op)
    def float? = ty == :float
    def to_s = "v#{id}"
  end

  class Block
    attr_accessor :name, :phis, :insts, :cold
    def initialize(name) = (@name, @phis, @insts = name, [], [])
    def term = (t = insts.last; t if t&.term?)
    def <<(i) = (i.block = self; insts << i; i)
    def phi = (p = Inst.new(:phi, []); p.block = self; phis << p; p)
    def succs
      case term&.op
      when :br then [term.args[0]]
      when :condbr then term.args[1..2]
      else []
      end
    end
  end

  # a user class: ivar layout (8 bytes each, no header), methods, attrs
  class Klass
    attr_reader :name, :ivars, :methods, :readers, :writers
    def initialize(name) = (@name, @ivars, @methods, @readers, @writers = name, [], {}, {}, {})
    def ivar(n) = (@ivars << n unless @ivars.include?(n); @ivars.index(n))
    def size = @ivars.size * 8
  end

  class Func
    attr_accessor :name, :params, :blocks, :ptypes, :rtype, :cls
    def initialize(name, nparams)
      @name, @params, @blocks = name, Array.new(nparams) { Inst.new(:param) }, [Block.new(:entry)]
    end
    def entry = blocks.first
    def new_block(n) = (b = Block.new(:"#{n}#{blocks.size}"); blocks << b; b)
    def all = blocks.flat_map { |b| b.phis + b.insts }

    def replace_uses(from, to)
      all.each do |i|
        i.op == :phi ? i.args.map! { |(bb, v)| [bb, v == from ? to : v] } : i.args.map! { |a| a == from ? to : a }
      end
    end

    def dump
      s = "func #{name}(#{params.join(', ')})\n"
      blocks.each do |b|
        s << "#{b.name}:#{b.cold ? ' (cold)' : ''}\n"
        b.phis.each { |p| s << "  #{p} = phi #{p.args.map { |(bb, v)| "[#{bb.name}: #{v}]" }.join(', ')}\n" }
        b.insts.each do |i|
          a = i.args.map { _1.is_a?(Block) ? _1.name : _1.is_a?(Func) ? _1.name : _1.to_s }.join(", ")
          s << (i.term? ? "  #{i.op} #{a}\n" : "  #{i}#{i.ty ? ":#{i.ty}" : ''} = #{i.op}#{i.cond ? ".#{i.cond}" : ''} #{a}\n")
        end
      end
      s
    end
  end
end
