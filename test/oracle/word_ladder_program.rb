# word ladder BFS with Set and a hand-rolled queue, string manipulation
require "set"
WORDS = %w[hit hot dot dog cog lot log lit hat cat cot].freeze
def neighbors(word, dict)
  out = []
  word.each_char.with_index do |_, i|
    ("a".."z").each do |c|
      cand = word.dup
      cand[i] = c
      out << cand if cand != word && dict.include?(cand)
    end
  end
  out
end
def ladder(from, to, words)
  dict = Set.new(words)
  queue = [[from, [from]]]
  seen = Set.new([from])
  until queue.empty?
    word, path = queue.shift
    return path if word == to
    neighbors(word, dict).each do |n|
      next if seen.include?(n)
      seen << n
      queue.push([n, path + [n]])
    end
  end
  nil
end
p ladder("hit", "cog", WORDS)
p ladder("hit", "cat", WORDS)
p ladder("hit", "xyz", WORDS)
puts neighbors("hot", Set.new(WORDS)).sort.join(" ")
