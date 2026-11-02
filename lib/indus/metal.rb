# Run machine code in-process: mmap, copy, mprotect, jump.
# Also hosts the resident compiler: when the program reaches a seam, the
# generated code calls back here; we compile the new method and rewrite its
# slot in the globals area. That slot write is the world-age bump.
module Indus
  module Metal
    LIBC = Fiddle::Handle::DEFAULT
    MMAP = Fiddle::Function.new(LIBC["mmap"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG], Fiddle::TYPE_VOIDP)
    MPROTECT = Fiddle::Function.new(LIBC["mprotect"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    ICACHE = Fiddle::Function.new(LIBC["sys_icache_invalidate"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)

    def self.place(code)
      size = (code.bytesize + 4095) & ~4095
      mem = MMAP.call(nil, size, 3, 0x1002, -1, 0)
      raise "mmap failed" if mem.to_i == -1
      mem[0, code.bytesize] = code
      raise "mprotect failed" unless MPROTECT.call(mem, size, 5).zero?
      ICACHE.call(mem, size)
      mem
    end

    def self.run(unit)
      mem = place(unit.code)
      heap = MMAP.call(nil, 1 << 28, 3, 0x1002, -1, 0)
      unless unit.seams.empty?
        # the resident compiler, reachable from machine code
        cb = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_LONG, [Fiddle::TYPE_LONG]) do |id|
          klass, src = unit.seams[id]
          t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          code, off, f = Indus.compile_method(unit, mem.to_i, klass, src)
          addr = place(code).to_i + off
          method = f.name.to_s.split("@").first # Greeter#hello
          heap[unit.globals.fetch(:"m_#{method}"), 8] = [addr].pack("Q")
          $stderr.puts "indus: seam #{id}: recompiled #{method} (#{code.bytesize} bytes) in #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(2)} ms; slot rewritten, world moved on" if ENV["SEAM_LOG"]
          0
        end
        heap[unit.globals.fetch(:__seam_cb), 8] = [cb.to_i].pack("Q")
        @keep = cb # must outlive the run
      end
      r = Fiddle::Function.new(mem, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG).call(heap)
      if ENV["HEAP"] && (off = unit.globals[:__heap_end])
        used = heap[off, 8].unpack1("Q") - heap.to_i - 4096
        $stderr.puts "indus: heap #{used >= 1 << 20 ? "#{(used / 1048576.0).round(1)} MB" : "#{used / 1024} KB"}"
      end
      r
    end
  end
end
