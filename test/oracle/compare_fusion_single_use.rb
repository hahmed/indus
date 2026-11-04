def t1(f)
  neg = f < 0.0
  a = neg ? 0.0 - f : f
  i = 0
  while i < 3
    a = a * 1.0
    i = i + 1
  end
  out = "v"
  neg ? "-" + out : out
end
puts t1(-0.5)
def t2(f)
  neg = f < 0.0
  a = neg ? 0.0 - f : f
  out = "v"
  neg ? "-" + out : out
end
puts t2(-0.5)
def t3(f)
  neg = f < 0.0
  out = "v"
  i = 0
  while i < 3
    i = i + 1
  end
  neg ? "-" + out : out
end
puts t3(-0.5)
