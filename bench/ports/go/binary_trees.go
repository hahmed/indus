package main

import "fmt"

type Node struct{ left, right *Node }

func makeTree(d int) *Node {
	if d == 0 {
		return &Node{}
	}
	return &Node{makeTree(d - 1), makeTree(d - 1)}
}
func check(n *Node) int {
	if n.left == nil {
		return 1
	}
	return 1 + check(n.left) + check(n.right)
}
func main() {
	maxDepth, minDepth := 10, 4
	stretch := makeTree(maxDepth + 1)
	fmt.Println(check(stretch))
	long := makeTree(maxDepth)
	for d := minDepth; d <= maxDepth; d += 2 {
		iters := 1 << uint(maxDepth-d+minDepth)
		c := 0
		for i := 1; i <= iters; i++ {
			c += check(makeTree(d))
		}
		fmt.Println(c)
	}
	fmt.Println(check(long))
}
