p [1, 2].map { it + 1 }, [1, 2].map { _1 * 2 }, [[1, 2]].map { _1 + _2 }, 5.then { _1 * 2 }, "ok".then { |s| s + "!" }, [1,2].then(&:sum), 3.tap { |x| puts x }
LIST = []
$g = []
def add(x) = (LIST << x; $g << x)
add(1); add(2)
p LIST, $g
