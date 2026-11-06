a = Array.new(5, 1)
a[2] += 10
a[3] -= 1
a[4] *= 3
puts a[2]
puts a[3]
puts a[4]
h = {"k" => 1}
h["k"] += 5
h["z"] ||= 9
puts h["k"]
puts h["z"]
class Dog
  def speak
    "woof"
  end
end
class Cat
  def speak
    "meow"
  end
end
pets = [Dog.new, Cat.new, Dog.new]
dogs = 0
i = 0
while i < pets.length
  dogs += 1 if pets[i].is_a?(Dog)
  i += 1
end
puts dogs
puts pets[1].is_a?(Cat)
puts pets[1].is_a?(Dog)
puts 5.is_a?(Integer)
puts "s".is_a?(String)
squares = (1..5).map { |n| n * n }
puts squares[4]
puts squares.length
names = ["a", "b"].map { |s| s + "!" }
puts names[1]
def greet(name, greeting: "hi", punct: "!")
  greeting + " " + name + punct
end
puts greet("bob")
puts greet("bob", greeting: "yo")
puts greet("bob", punct: "?", greeting: "hey")
total = 0
[3, 4, 5].each do |n|
  total += n
end
puts total
