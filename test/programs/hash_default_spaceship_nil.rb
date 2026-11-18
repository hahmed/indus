h = Hash.new(5)
p h.default, {}.default, h.default_proc
p 1 <=> "a", 1 <=> 2, "a" <=> 1, 1.5 <=> 1, 1 <=> nil
