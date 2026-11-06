memo = Hash.new { |h, k| h[k] = k < 2 ? k : h[k - 1] + h[k - 2] }
p memo[30], memo.size
words = Hash.new { |h, k| h[k] = [] }
words["a"] << 1; words["a"] << 2; words["b"] << 3
p words
