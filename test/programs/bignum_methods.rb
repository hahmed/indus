b = 2**64
p b.even?, b.odd?, (b+1).odd?, b.abs, (-b).abs, -b, b.to_s, b.to_f, b.bit_length, b.gcd(6), 6.lcm(b) rescue p $!
p b.fdiv(2), b.divmod(7), b.remainder(7), (b <=> 1), (1 <=> b), b == b, b.zero?, b.pred, b.digits.size, b.coerce(1), (b <=> "a"), b.eql?(b), ~b
