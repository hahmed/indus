# The collector's compile-time half: type descriptors and frame maps.
#
# Objects carry no header. What a pointer points at is known from the type
# of the slot holding it, so the collector is driven by two tables emitted
# as data:
#
#   TYPES  one descriptor per heap type:
#          kind 0 STR            size = 16 + cap            no pointers
#          kind 1 ARR  elem_tid  size = 16 + cap*8          elems if elem_tid >= 0
#          kind 2 HASH k_tid v_tid  size = 16 + cap*16      keys/vals if tid >= 0
#          kind 3 OBJ  size nfields [field_off, tid]...     (base 8 if tagged)
#          kind 4 POLY npairs [class_id, tid]...            tag in word 0 -> class
#          kind 5 DYN  str arr hash floatbox npairs [class_id, tid]...  by the value's low-bit tag
#   FRAMES one entry per function: [code_start, code_end, nslots, slot_off, tid...]
#          (code offsets relative to the text base; slots relative to that frame's sp)
#
# In GC mode the allocator keeps pointer-typed values that cross a call in
# frame slots (never in callee-saved registers), so the frame walk sees every
# root. Pointer slots are zeroed in the prologue; a stale pointer in a dead
# slot keeps an object alive one collection longer, which is safe.
module Indus
  module GC
    # on by default; INDUS_NOGC=1 turns it off
    def self.enabled? = !ENV["INDUS_NOGC"]
    def self.semispace_bytes = [(ENV["INDUS_HEAP_MB"] || 4).to_i, 1].max << 20 # start small (never 0); the collector doubles it on demand

    def self.pointer?(t) = Types.heap_pointer?(t)
    # classes reachable through a :dyn slot need their id in word 0
    def self.dyn_classes(classes) = classes.values.select(&:tagged)

    # ops that bump the heap themselves (calls are decided by their callee)
    DIRECT_ALLOC = %i[anew aset onew hnew hset hkeys sconst scat sappend ssub itos box chr].freeze

    # Func#allocates: can running this function (transitively) allocate? A call
    # to a function that cannot needs no safepoint. Patchable methods may be
    # replaced by anything at run time, so they always count.
    def self.mark_allocators(funcs)
      funcs.each { |f| f.allocates = f.patchable || f.all.any? { |i| DIRECT_ALLOC.include?(i.op) } }
      loop do
        changed = false
        funcs.each do |f|
          next if f.allocates
          f.all.each do |i|
            callees = case i.op
                      when :call then [i.args[0]]
                      when :pcall then i.args[0].filter_map { |(_, kind, payload)| payload if kind == :call }
                      when :sendsw then i.args[0].filter_map { |(_, kind, payload)| payload if kind == :call }
                      else []
                      end
            if callees.any?(&:allocates) then f.allocates = true; changed = true; break end
          end
        end
        break unless changed
      end
    end

    def self.needs_safepoint?(i)
      return true if DIRECT_ALLOC.include?(i.op)
      case i.op
      when :call then i.args[0].allocates
      when :pcall, :sendsw then i.args[0].any? { |(_, kind, payload)| kind == :call && payload.allocates }
      else false
      end
    end

    class Table
      attr_reader :types
      def initialize(classes) = (@classes, @types, @ids = classes, [], {})

      # type -> descriptor id (interned; recursive types resolve through a placeholder)
      def tid(t)
        return -1 unless GC.pointer?(t)
        key = t.inspect
        return @ids[key] if @ids.key?(key)
        id = @ids[key] = @types.size
        @types << nil # placeholder for recursion
        @types[id] =
          case
          when t == :str then [0]
          when t == :dyn # a tagged scalar: the concrete type is known only at run time, by tag
            boxed = @classes.values.select(&:boxed)
            [5, tid(:str), tid([:arr, :dyn]), tid([:hash, :dyn, :dyn]), tid(:str), boxed.size, *boxed.flat_map { |k| [k.id, tid(k.name)] }]
          when t.is_a?(Array) && t[0] == :arr then [1, tid(t[1])]
          when t.is_a?(Array) && t[0] == :hash then [2, tid(t[1]), tid(t[2])]
          when t.is_a?(Array) && t[0] == :poly then [4, t[1].size, *t[1].flat_map { |c| [@classes[c].id, tid(c)] }]
          when t.is_a?(Symbol) && (k = @classes[t])
            fields = k.ivars.each_index.filter_map do |ix|
              ft = Types.ivar_type(t, ix)
              [k.base + ix * 8, tid(ft)] if GC.pointer?(ft)
            end
            [3, k.size, fields.size, *fields.flatten]
          else raise "gc: no descriptor for #{t.inspect}"
          end
        id
      end

      # words: [count, off_0, off_1, ...] then each descriptor
      def words
        offs = []; body = []
        @types.each { |d| offs << body.size; body.concat(d) }
        [@types.size, *offs.map { _1 + 1 + @types.size }, *body]
      end
    end
  end
end
