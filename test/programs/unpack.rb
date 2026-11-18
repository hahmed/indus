p "ABC".unpack("C*"), "\x01\x00\x00\x02".unpack("s<l>"), "abc  ".unpack("A*"), "abc\x00\x00".unpack("Z*a"), "aGVsbG8gd29ybGQ=\n".unpack("m"), "#86)C\n".unpack("u")
p "\xA0".unpack("B*"), "\xA1\xF0".unpack("H*"), "\x82,".unpack("w"), "☺a".unpack("U*"), "\x01\x02\x03".unpack("Cx1C"), "ABCD".unpack1("@2a2"), "AB".unpack("C3")
s = "hello"
p s.unpack("a2a3"), s.unpack1("a*")
