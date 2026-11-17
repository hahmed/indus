begin; raise ArgumentError, "x"; rescue Exception => e; p e.class.ancestors.map { |a| a.to_s }.include?("StandardError"), e.class.ancestors.map(&:to_s).first(3); end
class K < StandardError; end
p K.ancestors.map(&:to_s).first(3)
