def route(req)
  case req
  in { method: "GET", path: "/" } then "home"
  in { method: "GET", path: String => p } if p.start_with?("/users/") then "user #{p.split("/").last}"
  in { method: "POST", path: } then "create at #{path}"
  in [cmd, *rest] then "cmd #{cmd} #{rest.size}"
  in 1.. => n then "positive #{n}"
  in ..0 then "non-positive"
  else "unknown"
  end
end
puts route({ method: "GET", path: "/" }), route({ method: "GET", path: "/users/42" }), route({ method: "POST", path: "/x" })
puts route(["ls", "-l", "a"]), route(5), route(-2), route("zzz")
x = 5
case 5
in ^x then puts "pinned"
end
case [1, [2, 3]]
in [a, [b, c]] then p [a, b, c]
end
case { a: 1, b: { c: 2 } }
in { a: Integer => a, b: { c: } } then p [a, c]
end
v = [1, 2, 3]
case v
in [first, *] then p first
end
result = case 7
in Integer | Float then "num"
in String then "str"
end
puts result
