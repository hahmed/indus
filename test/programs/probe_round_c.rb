b = 10 ** 20
p b.class, b + 0.5, b * 1.5, b / 2.0, b > 1.5, Integer.sqrt(b), Integer.sqrt(17)
p 9223372036854775807 + 1, 1 << 64, 2 ** 63
p 1.5.dup, 1.5.floor(0), 12345.6789.ceil(-2), 3.7.truncate(-1), 15.truncate(-1), 1.5.integer?, 1.5.coerce(2), rand(0).class, rand(1.0).class
