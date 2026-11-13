key = +"foo"
h = {key => "bar"}
key.reverse!
p h["foo"], h.keys.first, key
p __LINE__
