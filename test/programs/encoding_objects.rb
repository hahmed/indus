s = "héllo"
p s.encoding, s.encoding.name, s.encoding == Encoding::UTF_8, s.valid_encoding?, "abc".ascii_only?, s.ascii_only?
p Encoding::BINARY.name, Encoding::UTF_8.ascii_compatible?
