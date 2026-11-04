# plain-Ruby stand-ins for the unsigned intrinsics, so grisu.rb can be tested
# against Float#to_s without the compiler. Not compiled into programs.
M64 = (1 << 64) - 1
def __fbits(f) = [f].pack("E").unpack1("Q")
def __lsr(a, n) = (a & M64) >> n
def __clz(a) = 64 - (a & M64).bit_length
def __umulh(a, b) = ((a & M64) * (b & M64)) >> 64
def __wmul(a, b) = (a * b) & M64
def __wadd(a, b) = (a + b) & M64
def __wsub(a, b) = (a - b) & M64
$__g = {}
def __gset_int(k, v) = $__g[k] = v
def __gget_int(k) = $__g[k]
def __ult(a, b) = (a & M64) < (b & M64)
def __ule(a, b) = (a & M64) <= (b & M64)
