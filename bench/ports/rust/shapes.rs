trait Shape { fn area(&self) -> i64; fn tag(&self) -> i64; }
struct Circle { r: i64 } struct Square { s: i64 } struct Rect { w: i64, h: i64 }
impl Shape for Circle { fn area(&self) -> i64 { 3 * self.r * self.r } fn tag(&self) -> i64 { 1 } }
impl Shape for Square { fn area(&self) -> i64 { self.s * self.s } fn tag(&self) -> i64 { 2 } }
impl Shape for Rect { fn area(&self) -> i64 { self.w * self.h } fn tag(&self) -> i64 { 3 } }
fn main() {
    let mut shapes: Vec<Box<dyn Shape>> = Vec::new();
    for i in 0..300i64 {
        match i % 3 { 0 => shapes.push(Box::new(Circle { r: i })), 1 => shapes.push(Box::new(Square { s: i })), _ => shapes.push(Box::new(Rect { w: i, h: 2 })) }
    }
    let (mut total, mut tags) = (0i64, 0i64);
    for _ in 0..20000 { for s in shapes.iter() { total += s.area(); tags += s.tag(); } }
    println!("{}", total); println!("{}", tags); println!("{}", shapes.len());
}
