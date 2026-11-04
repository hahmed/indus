# text processing without regexps
text = "the quick brown fox jumps over the lazy dog the end"
words = text.split
freq = Hash.new(0)
words.each { |w| freq[w] += 1 }
top = freq.sort_by { |w, c| [-c, w] }.first(3)
top.each { |w, c| puts "#{w.ljust(6)} #{c}" }
puts words.map(&:length).max
puts words.group_by(&:length).keys.sort.inspect
puts words.each_with_index.map { |w, i| "#{i}:#{w}" }.first(2).inspect
puts text.count("aeiou")
puts text.chars.uniq.length
puts words.each_with_object({}) { |w, h| h[w] = w.length }.size
puts words.partition { |w| w.length > 3 }.map(&:length).inspect
puts words.zip(words.rotate).first(2).inspect
puts words.min_by(&:length)
puts words.sort.last
puts words.reverse.take(2).inspect
puts words.join(" ").length == text.length
acronym = words.map { |w| w[0].upcase }.join
puts acronym
puts text.sub("quick", "slow").split.first(3).join(" ")
puts text.start_with?("the") && text.end_with?("end")
puts text.index("fox")
puts text[4..8]
puts text[-3..]
