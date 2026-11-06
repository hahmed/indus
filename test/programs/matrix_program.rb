# matrix / numeric work: nested arrays, floats, formatting, each_with_index
class Matrix
  attr_reader :rows
  def initialize(rows) = @rows = rows
  def self.identity(n) = new((0...n).map { |i| (0...n).map { |j| i == j ? 1.0 : 0.0 } })
  def n = @rows.size
  def [](i, j) = @rows[i][j]
  def *(other)
    res = (0...n).map do |i|
      (0...other.cols).map do |j|
        s = 0.0
        (0...other.n).each { |k| s += @rows[i][k] * other.rows[k][j] }
        s
      end
    end
    Matrix.new(res)
  end
  def cols = @rows[0].size
  def transpose = Matrix.new((0...cols).map { |j| (0...n).map { |i| @rows[i][j] } })
  def trace = (0...n).sum { |i| @rows[i][i] }
  def to_s = @rows.map { |r| r.map { |v| format("%6.2f", v) }.join(" ") }.join("\n")
end

a = Matrix.new([[1.0, 2.0], [3.0, 4.0]])
b = Matrix.new([[0.0, 1.0], [1.0, 0.0]])
puts (a * b).to_s
puts "--"
puts a.transpose.to_s
puts a.trace
puts Matrix.identity(3).to_s
puts a[1, 0]
puts (a * Matrix.identity(2)).rows.flatten.sum
