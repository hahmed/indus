class Y
  def z
    yield
  end
  def ze(&block)
    block = proc { block }
    yield
  end
end
y = Y.new
begin
  y.z
rescue LocalJumpError => e
  p e.class
end
p y.z { 3 }
begin; raise ZeroDivisionError, "x"; rescue StandardError => e; p e.class; end
begin; raise KeyError, "x"; rescue IndexError => e; p e.class, e.class.name; end
class MyE < StandardError; end
begin; raise MyE, "x"; rescue StandardError => e; p e.class; end
