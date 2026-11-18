module S
  class MyString < String; end
end
class MyArr < Array; end
p S::MyString.new("bla").upcase, "blablabla".index(S::MyString.new("bla"))
a = MyArr.new
a << 1
p a
