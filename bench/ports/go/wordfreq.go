package main

import "fmt"

func main() {
	words := []string{"the", "of", "and", "to", "in", "a", "is", "that", "for", "it", "was", "on", "are", "be", "with", "as", "at", "by", "this", "from"}
	n := 10000
	result := make([]string, 0, n)
	seed := int64(42)
	for i := 0; i < n; i++ {
		seed = (seed*1103515245 + 12345) % 2147483648
		result = append(result, words[seed/107374182])
	}
	freq := map[string]int64{}
	for _, w := range result {
		if _, ok := freq[w]; ok {
			freq[w] = freq[w] + 1
		} else {
			freq[w] = 1
		}
	}
	keys := make([]string, 0, len(freq))
	for k := range freq {
		keys = append(keys, k)
	}
	var total int64
	for _, k := range keys {
		total += freq[k]
	}
	fmt.Println(total)
	fmt.Println(len(keys))
}
