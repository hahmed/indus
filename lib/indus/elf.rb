# Writes a static arm64 Linux ELF executable from raw machine code. No linker.
# One PT_LOAD segment holding headers + code. No sections, no signing.
module Indus
  module ELF
    BASE = 0x400000
    EHDR = 64
    PHDR = 56

    def self.write(path, code, entry_off: 0)
      off = EHDR + PHDR
      entry = BASE + off + entry_off
      ehdr = [
        "\x7FELF".b, 2, 1, 1, 0, "",          # magic, 64-bit, little-endian, version, SysV ABI, pad
        2, 0xB7, 1,                           # ET_EXEC, EM_AARCH64, version
        entry, EHDR, 0,                       # entry, phoff, shoff
        0, EHDR, PHDR, 1, 64, 0, 0            # flags, ehsize, phentsize, phnum, shentsize, shnum, shstrndx
      ].pack("a4 C C C C a8 v v V Q Q Q V v v v v v v")
      filesz = off + code.bytesize
      phdr = [1, 5, 0, BASE, BASE, filesz, filesz, 0x10000].pack("V V Q Q Q Q Q Q") # PT_LOAD, R+X
      File.binwrite(path, ehdr + phdr + code)
      File.chmod(0755, path)
      path
    end
  end
end
