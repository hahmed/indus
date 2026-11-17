def f(x) = x ? "s" : nil
def g(x) = x ? [1] : nil
class K; end
def h(x) = x ? K.new : nil
mixed = [f(false), g(false), h(false), f(true), 1]
p mixed[0].nil?, mixed[1].nil?, mixed[2].nil?, mixed[3].nil?, mixed.compact.size
