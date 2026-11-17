module M1; X = :m1; def self.x = X; end
module M2; X = :m2; def self.x = X; end
class A; X = :a; def x = X; end
class B < A; def x2 = X; end
module Outer; Y = :oy; class In; def y = Y; end; end
p M1.x, M2.x, M1::X, M2::X, A.new.x, B.new.x2, Outer::In.new.y, Outer::Y, A::X
