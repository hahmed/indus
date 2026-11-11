class A1; def self.method_added(m) = puts("added #{m}"); def x = 1; end
module M; def self.included(b) = puts("included in #{b}"); def self.extended(o) = puts("extended #{o}"); end
class A1; include M; end
class B; extend M; end
module Tr; def self.included(b) = b.extend(CM); module CM; def cm = :cm; end; end; class A; include Tr; end; p A.cm
