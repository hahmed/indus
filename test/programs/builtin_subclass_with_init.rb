module S
  class MyArray < Array
    def initialize(a, b)
      self << a << b
    end
  end
end
a = S::MyArray[1, 2, 3]
p a, a.map { |x| x + 1 }, Array[4, 5]
