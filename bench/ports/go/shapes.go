package main

import "fmt"

type Shape interface {
	Area() int64
	Tag() int64
}
type Circle struct{ r int64 }
type Square struct{ s int64 }
type Rect struct{ w, h int64 }

func (c *Circle) Area() int64 { return 3 * c.r * c.r }
func (c *Circle) Tag() int64  { return 1 }
func (s *Square) Area() int64 { return s.s * s.s }
func (s *Square) Tag() int64  { return 2 }
func (r *Rect) Area() int64   { return r.w * r.h }
func (r *Rect) Tag() int64    { return 3 }

func main() {
	shapes := []Shape{}
	for i := int64(0); i < 300; i++ {
		switch i % 3 {
		case 0:
			shapes = append(shapes, &Circle{i})
		case 1:
			shapes = append(shapes, &Square{i})
		default:
			shapes = append(shapes, &Rect{i, 2})
		}
	}
	var total, tags int64
	for k := 0; k < 20000; k++ {
		for j := 0; j < 300; j++ {
			s := shapes[j]
			total += s.Area()
			tags += s.Tag()
		}
	}
	fmt.Println(total)
	fmt.Println(tags)
	fmt.Println(len(shapes))
}
