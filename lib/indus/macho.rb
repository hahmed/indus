# Writes an arm64 Mach-O executable from raw machine code. No linker.
#
# macOS refuses to run static executables (AppleSystemPolicy kills them), so
# this is a dyld-loaded binary with the minimum dyld accepts: empty chained
# fixups, empty exports trie, empty symbol table, libSystem as the one
# dependency (never called -- I/O is raw syscalls), LC_MAIN for entry, and
# the ad-hoc code signature (SHA-256 page hashes) Apple Silicon requires.
require "digest"

module Indus
  module MachO
    PAGE = 0x4000
    BASE = 0x100000000

    def self.write(path, code, entry_off: 0)
      # ---- __LINKEDIT payload (everything but the signature) ---------------
      fixups = [0, 32, 48, 48, 0, 1, 0].pack("V7") + "\0" * 4 + [3, 0, 0, 0].pack("V4") # header(28)+pad, starts_in_image{seg_count=3, offsets=0} at 32, imports/symbols at 48
      fixups << "\0" * (8 - fixups.bytesize % 8) if fixups.bytesize % 8 != 0
      trie = "\0" * 8
      symtab = ""                       # nsyms = 0
      strtab = "\0" * 8
      linkedit = fixups + trie + symtab + strtab
      le_fixups_off, le_trie_off, le_sym_off, le_str_off = 0, fixups.bytesize, fixups.bytesize + trie.bytesize, fixups.bytesize + trie.bytesize

      # ---- load commands -------------------------------------------------
      dyld_path = "/usr/lib/dyld\0".ljust(20, "\0")           # cmd 12 + 20 = 32
      libsys = "/usr/lib/libSystem.B.dylib\0".ljust(32, "\0")  # cmd 24 + 32 = 56
      sizes = { seg0: 72, text: 72 + 80, le: 72, fixups: 16, trie: 16, symtab: 24, dysymtab: 80,
                dylinker: 32, uuid: 24, build: 24, srcver: 16, main: 24, dylib: 56, fstarts: 16, dic: 16, sig: 16 }
      header_size = 32 + sizes.values.sum
      ncmds = sizes.size

      text_file_size = header_size + code.bytesize
      text_vmsize = align(text_file_size, PAGE)
      le_off = text_vmsize
      sig_off = le_off + align(linkedit.bytesize, 16)
      sig_size = signature(nil, sig_off, text_vmsize).bytesize
      le_size = (sig_off - le_off) + sig_size

      seg = ->(name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sects) {
        [0x19, 72 + 80 * sects.size, name.ljust(16, "\0"), vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sects.size, 0].pack("VVa16QQQQVVVV") + sects.join
      }
      section = ->(sname, segname, addr, size, off) {
        [sname.ljust(16, "\0"), segname.ljust(16, "\0"), addr, size, off, 2, 0, 0, 0x80000400, 0, 0, 0].pack("a16a16QQVVVVVVVV")
      }
      lede = ->(cmd, off, size) { [cmd, 16, le_off + off, size].pack("V4") }

      cmds = +""
      cmds << seg.("__PAGEZERO", 0, BASE, 0, 0, 0, 0, [])
      cmds << seg.("__TEXT", BASE, text_vmsize, 0, text_vmsize, 5, 5,
                   [section.("__text", "__TEXT", BASE + header_size, code.bytesize, header_size)])
      cmds << seg.("__LINKEDIT", BASE + text_vmsize, align(le_size, PAGE), le_off, le_size, 1, 1, [])
      cmds << lede.(0x80000034, le_fixups_off, fixups.bytesize)                 # LC_DYLD_CHAINED_FIXUPS
      cmds << lede.(0x80000033, le_trie_off, trie.bytesize)                     # LC_DYLD_EXPORTS_TRIE
      cmds << [0x2, 24, le_off + le_sym_off, 0, le_off + le_str_off, strtab.bytesize].pack("V6") # LC_SYMTAB
      cmds << ([0xB, 80] + [0] * 18).pack("V20")                                 # LC_DYSYMTAB (all zero)
      cmds << [0xE, 32, 12].pack("V3") + dyld_path                               # LC_LOAD_DYLINKER
      cmds << [0x1B, 24].pack("VV") + Digest::MD5.digest(code)                   # LC_UUID
      cmds << [0x32, 24, 1, 0x001B0000, 0x001B0000, 0].pack("V6")                # LC_BUILD_VERSION macos 27
      cmds << [0x2A, 16, 0].pack("VVQ")                                           # LC_SOURCE_VERSION
      cmds << [0x80000028, 24, header_size + entry_off, 0].pack("VVQQ")          # LC_MAIN
      cmds << [0xC, 56, 24, 2, 0x10000, 0x10000].pack("V6") + libsys             # LC_LOAD_DYLIB libSystem
      cmds << lede.(0x26, le_trie_off, 0)                                         # LC_FUNCTION_STARTS (empty)
      cmds << lede.(0x29, le_trie_off, 0)                                         # LC_DATA_IN_CODE (empty)
      cmds << [0x1D, 16, sig_off, sig_size].pack("V4")                           # LC_CODE_SIGNATURE
      raise "header size #{32 + cmds.bytesize} != #{header_size}" unless 32 + cmds.bytesize == header_size

      header = [0xFEEDFACF, 0x0100000C, 0, 2, ncmds, cmds.bytesize, 0x00200085, 0].pack("V8") # NOUNDEFS|DYLDLINK|TWOLEVEL|PIE
      body = header + cmds + code
      body << "\0" * (text_vmsize - body.bytesize)
      body << linkedit
      body << "\0" * (sig_off - body.bytesize)
      body << signature(body, sig_off, text_vmsize)
      File.binwrite(path, body)
      File.chmod(0755, path)
      path
    end

    def self.align(n, a) = (n + a - 1) & ~(a - 1)

    def self.signature(body, code_limit, exec_limit)
      ident = "indus\0"
      npages = (code_limit + 4095) / 4096
      hashes = body ? npages.times.map { |i| Digest::SHA256.digest(body.byteslice(i * 4096, [4096, code_limit - i * 4096].min)) } : ["\0" * 32] * npages
      ident_off = 88
      hash_off = ident_off + ident.bytesize
      cd_len = hash_off + 32 * npages
      cd = [0xFADE0C02, cd_len, 0x20400, 0x20002, hash_off, ident_off, 0, npages,
            code_limit, 32, 2, 0, 12, 0, 0, 0, 0, 0, 0, exec_limit, 1].pack("N4 N4 N C4 N N3 Q4") + ident + hashes.join
      # linker-signed: CodeDirectory only, exactly what ld emits. Gatekeeper
      # treats that as locally built and skips the notarization lookup.
      [0xFADE0CC0, 12 + 8 + cd.bytesize, 1, 0, 20].pack("N5") + cd
    end
  end
end
