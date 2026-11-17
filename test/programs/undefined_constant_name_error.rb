def f = NOPE
x = (f rescue "caught")
p x
begin; f; rescue NameError => e; puts e.message; end
