class Model
  def self.attribute(name, default: nil)
    define_method(name) { instance_variable_defined?("@#{name}") ? instance_variable_get("@#{name}") : default }
    define_method("#{name}=") { |v| instance_variable_set("@#{name}", v) }
  end
  def self.attributes(*names) = names.each { |n| attribute(n) }
end
class User < Model
  attribute :email
  attribute :age, default: 18
  attributes :first, :last
  def full = "#{first} #{last}"
end
u = User.new
u.email = "a@b"; u.first = "A"; u.last = "B"
p u.email, u.age, u.full
u.age = 30
p u.age
