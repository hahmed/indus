package main

import (
	"fmt"
	"strconv"
)

type Row struct {
	name string
	qty  int64
}

func (r *Row) line() string { return r.name + ": " + strconv.FormatInt(r.qty, 10) + " units" }

func main() {
	rows := []*Row{}
	for i := int64(0); i < 100; i++ {
		rows = append(rows, &Row{"item" + strconv.FormatInt(i, 10), i * 3})
	}
	total, hits := 0, 0
	for k := 0; k < 2000; k++ {
		out := ""
		for j := 0; j < 100; j++ {
			l := rows[j].line()
			out += l
			out += "\n"
			if l == "item7: 21 units" {
				hits++
			}
		}
		total += len(out)
	}
	fmt.Println(total)
	fmt.Println(hits)
	fmt.Println(rows[7].line())
}
