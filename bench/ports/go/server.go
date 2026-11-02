package main

import (
	"fmt"
	"strconv"
)

type Request struct {
	id     int64
	path   string
	params []int64
}

func newRequest(id int64) *Request {
	p := make([]int64, 4)
	p[0] = id
	p[1] = id * 2
	return &Request{id, "/items/" + strconv.FormatInt(id, 10), p}
}
func (r *Request) checksum() int64 { return int64(len(r.path)) + r.params[0] + r.params[1] }

func main() {
	kept := []*Request{}
	var total int64
	for i := int64(0); i < 400000; i++ {
		r := newRequest(i)
		total += r.checksum()
		if i%500 == 0 {
			kept = append(kept, r)
		}
	}
	fmt.Println(total)
	fmt.Println(len(kept))
	var s int64
	for _, r := range kept {
		s += r.checksum()
	}
	fmt.Println(s)
	fmt.Println(kept[300].path)
}
