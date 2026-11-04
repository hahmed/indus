def add_field(line, value, first)
  line << "," unless first
  line << value
  line
end

def build_row(fields)
  line = +""
  i = 0
  while i < fields.length
    add_field(line, fields[i], i == 0)
    i = i + 1
  end
  line
end

def pad(buf, n)
  while buf.length < n
    buf << "."
  end
end

rows = []
k = 0
while k < 3
  rows.push(build_row(["a" + k.to_s, "bb", "ccc"]))
  k = k + 1
end
puts rows[2]
puts rows.length
r = rows[0]
pad(r, 20)
puts r
puts rows[0]
puts rows[0].length
s = "x"
add_field(s, "y", false)
add_field(s, "z", false)
puts s
big = ""
j = 0
while j < 2000
  add_field(big, "word" + j.to_s, j == 0)
  j = j + 1
end
puts big.length
