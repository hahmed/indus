begin; "hello".freeze.upcase!; rescue FrozenError => e; p e.message; end
s = "abc".freeze
begin; s << "d"; rescue FrozenError => e; p e.class; end
a = [1]
a.freeze
begin; a << 2; rescue FrozenError => e; p e.class; end
t = "ok"
t << "!"
p t, s, a
u = "x".freeze
u = "y"
u << "z"
p u
