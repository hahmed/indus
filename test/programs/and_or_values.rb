p 5 && "str", nil && 1, (1 || 2), (false || "y"), ("a" && "b")
s = "ab"; p s =~ /b/ && s[1]
a = [1]; p a && a.size
x = 3 > 1 && 2 > 1; p x
h = {a: 1}; p(h[:a] || 10)
