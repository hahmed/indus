# the format prelude under CRuby, against CRuby's own format; dyn boxing stubbed
require_relative "../../lib/indus/rt/format"
def __ld8(s, i) = s.getbyte(i)
def __st8(s, i, v) = s.setbyte(i, v)
def __salloc(n) = "\0" * n
def __trap = raise("trap")
def __tag(v) = v.is_a?(Integer) ? 1 : v.is_a?(Float) ? 14 : v.is_a?(String) ? 2 : 0
def __unbox_int(v) = v
def __unbox_float(v) = v
def __dyn_to_s(v) = v.to_s
cases = [["%d", [42]], ["%5d|", [42]], ["%-5d|", [42]], ["%05d", [-42]], ["%+d", [7]], ["%x", [255]], ["%o", [8]], ["%b", [5]],
         ["%s-%s", ["a", "b"]], ["%10s|", ["hi"]], ["%-6s|", ["hi"]], ["%.2s", ["hello"]], ["%f", [3.14159]], ["%.2f", [3.14159]],
         ["%05.2f", [3.14159]], ["%8.3f|", [2.0]], ["%.0f", [2.5]], ["%e", [12345.678]], ["%.2e", [0.00123]], ["%c", [65]], ["100%%", []],
         ["%d items %s", [3, "left"]], ["%3d|%-3d|%03d", [1, 2, 3]], ["%.3f", [-1.0005]], ["%+.1f", [2.25]]]
cases.each { |fmt, args| got = __format(fmt, args); want = format(fmt, *args); got == want or abort("#{fmt.inspect} #{args.inspect}: got #{got.inspect} want #{want.inspect}") }
puts "format: ok (#{cases.size} cases)"
