# SSA IR: values, blocks, functions.
module Indus
  class Inst
    attr_accessor :bound_to # the generic instance a call last took its result type from
    attr_accessor :assumed # [operand, type] an irreversible by-type rewrite relied on; checked after typing
    attr_accessor :hoisted # a const moved to a loop preheader: lives in a register across the loop
    attr_accessor :kind, :ngrown # aslot: type of the kept value; hrestore: how many grown handles precede the slots
    attr_accessor :routed # the method name a call was routed from by the receiver's builtin family
    attr_accessor :nocheck # an add/sub/mul whose range analysis proves it cannot overflow
    attr_accessor :nonneg # a div/mod whose operands are provably non-negative: no floor fix-up
    attr_accessor :op, :args, :block, :reg, :cond, :slot, :shared, :ty, :stack, :home, :uses
    attr_accessor :strict # to_i from Kernel#Integer: junk raises
    attr_accessor :raw_shift # a shift the helper itself performs (count already checked)
    attr_accessor :dyn_split # the builtin arm of a tag branch (Types.split_dyn_object): not split again
    attr_reader :id
    @@n = 0
    def initialize(op, args = [], cond = nil) = (@op, @args, @cond, @id = op, args, cond, @@n += 1)
    def term? = %i[br condbr ret].include?(op)
    def call? = %i[zcheck call mcall pcall dsend sendsw puts_i puts_s puts_str eputs_str clock sys try_push raise puts_bool puts_opt p_opt puts_nil puts_nil_word p_str print_i print_str putc anew aset onew ipow seam sconst scat sjoin sappend seq sne scmp itos stoi bool_to_s chr box sdup salloc cell_new mkbuf bufappend libm fpow hnew hget hset hkey hkeys ssub rawmmap rawmunmap gc_now].include?(op) || (op == :hrestore && args.size > 2 + (ngrown || 0)) # a restore with kept values calls rt_keep_*
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
      edges = case term&.op
              when :br then [term.args[0]]
              when :condbr then term.args[1..2]
              else []
              end
      # a handler block is entered by rt_raise, not by a branch: an edge for reachability
      # and layout; the handler's locals come from the try's entry state (lowering), not phis
      edges + insts.select { _1.op == :try_push }.map { _1.args[0] }
    end
  end

  # a user class: ivar layout (8 bytes each, no header), methods, attrs
  class Klass
    attr_reader :name, :ivars, :methods, :readers, :writers
    attr_accessor :nullable_ivars # ivars written only by ||= / &&= somewhere: nil before the first write
    attr_accessor :dyn_ivars # ivars typed dyn by decree: the spare slots a run-time class_eval may name
    attr_accessor :ie_self # a closure whose self (field 0) is set by instance_eval at the call
    SPARES = 4
    # a run-time class_eval may add ivars: reserve dyn-typed spare slots (zero = nil) that the resident compiler names later
    def reserve_spares
      return if @spare_base
      @spare_base = @ivars.size
      SPARES.times { |i| ivar(:"@__spare#{i}"); (@dyn_ivars ||= []) << :"@__spare#{i}" }
    end
    # the resident compiler names a new ivar: it takes the next spare slot
    def claim_spare(name)
      ix = @ivars.index { _1.to_s.start_with?("@__spare") } or raise "#{@name} has no room for a new ivar #{name} (#{SPARES} spare slots per class_eval'd class)"
      @dyn_ivars[@dyn_ivars.index(@ivars[ix])] = name; @ivars[ix] = name
      ix
    end
    attr_accessor :hidden # method name -> true when private/protected (respond_to? is false; calls still resolve)
    attr_accessor :superclass, :tagged, :boxed, :id, :closure, :mixins, :enumerable, :outer # outer: the class a closure's self belongs to # closure: a lambda literal's anonymous class; mixins: modules included/prepended here
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
    attr_accessor :strict_arity # a lambda (->(){} / lambda {}): the wrong argument count is an error, not nil-padding
    attr_accessor :primary, :versions # a method defined again later: versions behind the primary's slot (see Lower#register_class_body)
    attr_accessor :name, :params, :blocks, :ptypes, :rtype, :cls, :patchable, :leaks, :stores_param, :stores_other, :returns_fresh, :rest, :allocates, :result_unused,
                  :shadowed # the definition this one overrides in the same class's chain (a mixin's, or the one a prepend covers): super's target
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

    # use counts, for decisions like fusing a compare into its branch
    def count_uses!
      all.each { _1.uses = 0 }
      params.each { _1.uses = 0 }
      all.each { |i| (i.op == :phi ? i.args.map(&:last) : i.args).each { _1.uses += 1 if _1.is_a?(Inst) && _1.uses } }
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
            when Array then x.map { |arm| arm.is_a?(Array) ? "#{arm[0].respond_to?(:name) ? arm[0].name : arm[0]}->#{arm[2].is_a?(Func) ? arm[2].name : arm[2]}" : arm.to_s }.join(" | ")
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
