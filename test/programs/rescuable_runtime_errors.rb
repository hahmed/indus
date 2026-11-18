class A; end
begin
  A.new.zap
rescue NoMethodError => e
  p e.message
end
begin; {a: 1}.fetch(:b); rescue KeyError => e; p e.class; end
begin; [[1, 2], [3]].transpose; rescue IndexError => e; p e.class; end
begin; "a" * -1; rescue ArgumentError => e; p e.class; end
puts "after"
