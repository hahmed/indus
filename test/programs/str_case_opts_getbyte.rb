p "aBc".downcase(:ascii), "abc".upcase(:ascii), (+"aBc").swapcase!(:ascii), "abc".capitalize(:turkic), "abc".getbyte(1), "abc".getbyte(5), "".ord rescue p $!
s = +"abc"
s.setbyte(0, 65)
p s
