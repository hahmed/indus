module MC; def mc = :c; end
class Outer
  class Inner
    include MC
    class << self
      include MC
    end
  end
end
p Outer::Inner.new.mc, Outer::Inner.mc
module MC; def mc = :c; end
include MC
p mc
