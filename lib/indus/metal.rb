# Run machine code in-process: mmap, copy, mprotect, jump.
module Indus
  module Metal
    LIBC = Fiddle::Handle::DEFAULT
    MMAP = Fiddle::Function.new(LIBC["mmap"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG], Fiddle::TYPE_VOIDP)
    MPROTECT = Fiddle::Function.new(LIBC["mprotect"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    ICACHE = Fiddle::Function.new(LIBC["sys_icache_invalidate"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID)

    def self.run(code)
      size = (code.bytesize + 4095) & ~4095
      mem = MMAP.call(nil, size, 3, 0x1002, -1, 0)
      raise "mmap failed" if mem.to_i == -1
      mem[0, code.bytesize] = code
      raise "mprotect failed" unless MPROTECT.call(mem, size, 5).zero?
      ICACHE.call(mem, size)
      heap = MMAP.call(nil, 1 << 28, 3, 0x1002, -1, 0)
      Fiddle::Function.new(mem, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG).call(heap)
    end
  end
end
