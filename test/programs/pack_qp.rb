p ["héllo=\n"].pack("M"), ["a" * 80].pack("M"), ["a" * 73].pack("M"), ["a" * 74].pack("M"), ["abc"].pack("M").unpack1("M"), "h=C3=A9llo=3D=\n".unpack1("M").bytes.size
