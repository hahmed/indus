package main

import "fmt"

func main() {
	var sum int64
	for i := int64(1); i <= 500000000; i++ {
		sum += i % 7
	}
	fmt.Println(sum)
}
