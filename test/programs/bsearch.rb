a = [1, 3, 5, 7, 9]
p a.bsearch { |x| x >= 4 }, a.bsearch { |x| x >= 100 }, a.bsearch_index { |x| x >= 7 }, [].bsearch { |x| true }
t = 6
p a.bsearch { |x| x > t }
