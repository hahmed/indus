p [65, 66, 67].pack("C*"), [1, 2].pack("s<l>"), ["abc"].pack("a5"), ["abc"].pack("A5"), ["abc"].pack("Z*"), ["hello world"].pack("m"), ["hello"].pack("m0"), ["abc"].pack("u")
p ["1010"].pack("B*"), ["1010"].pack("b*"), ["a1f"].pack("H*"), ["a1f"].pack("h*"), [300].pack("w"), [0x263A].pack("U"), [1, 2].pack("Cx2C"), ["ab", "cd"].pack("a@4a")
x = [1, 2, 3]
p x.pack("C*"), x.pack("n*"), x.pack("N*").bytes, [1].pack("q").bytes
