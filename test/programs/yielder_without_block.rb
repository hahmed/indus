def each_pair_ish
  return [1,2].map { |x| x } unless block_given?
  yield 1
  yield 2
end
p each_pair_ish
each_pair_ish { |x| puts x }
class K
  def run
    return 5 unless block_given?
    yield 7
  end
end
p K.new.run
K.new.run { |v| p v }
