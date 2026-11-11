class A; [:x, :y].each { |n| define_method("get_#{n}") { n } }; end; p A.new.get_x
