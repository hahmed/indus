def nb(word)
  out = []
  word.each_char.with_index do |_, i|
    cand = word.dup
    puts "i=#{i} #{i.class}"
    cand[0] = "c"
    out << cand
  end
  out
end
pair = ["hot", ["hot"]]
queue = [pair]
w, path = queue.shift
puts nb(w).inspect
puts nb("hot").inspect
