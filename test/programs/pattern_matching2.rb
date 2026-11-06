def kind(v)
  case v
  in Integer => n if n > 100 then "big #{n}"
  in Integer then "int"
  in String then "str"
  in [a, b] then "pair #{a} #{b}"
  in { name: String => nm } then "named #{nm}"
  in nil then "nil"
  else "other"
  end
end
puts kind(5), kind(500), kind("x"), kind([1, 2]), kind({ name: "bob" }), kind(nil), kind(2.5)
