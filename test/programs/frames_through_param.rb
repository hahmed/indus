class I
  def visit(node, env)
    if node == 0
      env["x"]
    elsif node == 1
      env["x"] = 7
      0
    else
      frame = {}
      [1].each { |p| frame["x"] = visit(p, env) }
      visit(0, frame)
    end
  end
end
puts I.new.visit(2, {})
