class Y
  def z
    yield
  end
end
@y = Y.new
begin; @y.z; rescue LocalJumpError => e; p e.class; end
l = -> { @y.z }
begin; l.call; rescue LocalJumpError => e; p e.class; end
p(@y.z { 7 })
