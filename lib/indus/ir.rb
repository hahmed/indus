# SSA IR: values, blocks, functions.
module Indus
  class Inst
    attr_accessor :op, :args, :block, :reg, :cond, :slot, :shared, :ty, :stack
    attr_reader :id
    @@n = 0
    def initialize(op, args = [], cond = nil) = (@op, @args, @cond, @id = op, args, cond, @@n += 1)
    def term? = %i[br condbr ret].include?(op)
    def call? = %i[call mcall pcall puts_i puts_s puts_str puts_bool puts_opt puts_nil putc anew aset onew ipow seam sconst scat sappend seq itos hnew hget hset hkey hkeys ssub].include?(op)
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
    attr_accessor :superclass, :tagged, :id
    def initialize(name, superclass = nil)
      @name, @methods, @readers, @writers = name, {}, {}, {}
      @superclass = superclass
      @ivars = superclass ? superclass.ivars.dup : [] # parent's fields first, same offsets
    end
    def ivar(n) = (@ivars << n unless @ivars.include?(n); @ivars.index(n))
    # a class that ever meets another in a poly slot carries its id in word 0
    def base = tagged ? 8 : 0
    def size = @ivars.size * 8 + base
    def find_method(n) = methods[n] || superclass&.find_method(n)
    def find_reader(n) = readers[n] || superclass&.find_reader(n)
    def find_writer(n) = writers[n] || superclass&.find_writer(n)
  end

  class Func
    attr_accessor :name, :params, :blocks, :ptypes, :rtype, :cls, :patchable, :leaks, :stores_param, :stores_other
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
          a = i.args.map do |x|
            case x
            when Block, Func, Klass then x.name
            when Array then x.map { |arm| arm.is_a?(Array) ? "#{arm[0].name}->#{arm[2].is_a?(Func) ? arm[2].name : arm[2]}" : arm.to_s }.join(" | ")
            else x.to_s
            end
          end.join(", ")
          s << (i.term? ? "  #{i.op} #{a}\n" : "  #{i}#{i.ty ? ":#{i.ty}" : ''} = #{i.op}#{i.cond ? ".#{i.cond}" : ''} #{a}\n")
        end
      end
      s
    end
  end
end
