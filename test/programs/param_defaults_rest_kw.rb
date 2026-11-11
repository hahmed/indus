class A; def m(a, b = a * 2, *rest, c:, d: c + 1, **o) = [a, b, rest, c, d, o]; end; p A.new.m(1, c: 5), A.new.m(1, 2, 3, c: 5, d: 6, e: 7)
