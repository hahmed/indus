module Top
  class ::Object
    module Wrap
      module D; def dd = 1; end
    end
  end
end
class C; include D; end
p C.new.dd
