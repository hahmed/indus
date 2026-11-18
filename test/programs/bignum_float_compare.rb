def bv(plus = 0)
  0x1_0000_0000_0000_0000 + plus
end
p(-bv(0xffff) <=> -bv.to_f, bv <=> 2.0, (bv <=> bv.to_f), bv.fdiv(2.0))
