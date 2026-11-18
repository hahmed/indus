def r1(a) = (return *a)
def r2 = (return 1, 2)
p r1([3, 4]), r2
x = [1, 2]
y = 2
case y
when *x then puts "in"
else puts "out"
end
case 5
when *x, 5 then puts "five"
end
r = [1,2,3].each { |i| break *[i, i] if i == 2 }
p r
