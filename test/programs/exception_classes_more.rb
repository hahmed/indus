begin; raise SyntaxError, "x"; rescue ScriptError => e; p e.class; end
p FrozenError.ancestors.first(3).map(&:to_s)
