class P
  X = :p
  def self.c22; yield; end
  def self.go = 1
end
class Q
  X = :q
  def self.c22 = P.c22 { X }
end
p Q.c22, P.c22 { 5 }
