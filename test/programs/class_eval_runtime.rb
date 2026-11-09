class A; def a = 1; def b = 5; end
x = A.new
p x.a
body = "def a = 2"
A.class_eval body
p x.a
n = 7
A.class_eval "def a = #{n}"
p x.a
src = ["def a = 20", "def b = 60"].join("\n")
A.class_eval src
p x.a, x.b
