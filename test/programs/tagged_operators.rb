def pick(i)
  return "a" if i == 0
  return 7 if i == 1
  return 2.5 if i == 2
  return nil if i == 3
  false
end
puts pick(1) + pick(1)
puts pick(0) + pick(0)
puts pick(1) + pick(2)
puts pick(2) * pick(1)
puts pick(1) < pick(2)
puts pick(1) == 7
puts pick(0) == "a"
puts pick(3) == nil
puts pick(3) ? "t" : "f"
puts pick(4) ? "t" : "f"
puts pick(1) ? "t" : "f"
puts pick(0) ? "t" : "f"
x = pick(1) - pick(1)
puts x
