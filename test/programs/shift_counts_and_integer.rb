x = 3; k = -1; x <<= k; p x
p 3 << -1, 48 >> -1, -8 >> 1, 1 << 62, 5 >> 70, -5 >> 70
p ["1", "x"].map { |s| Integer(s) rescue nil }
p Integer("nope") rescue p $!.class
p Integer("12"), Integer(3.7), "7".to_i, "x".to_i, Integer("0b101"), Integer(" -1_000 ")
