struct Node { left: Option<Box<Node>>, right: Option<Box<Node>> }
fn make(d: i64) -> Box<Node> {
    if d == 0 { Box::new(Node { left: None, right: None }) }
    else { Box::new(Node { left: Some(make(d - 1)), right: Some(make(d - 1)) }) }
}
fn check(n: &Node) -> i64 {
    match &n.left { None => 1, Some(l) => 1 + check(l) + check(n.right.as_ref().unwrap()) }
}
fn main() {
    let (max_depth, min_depth) = (10i64, 4i64);
    let stretch = make(max_depth + 1);
    println!("{}", check(&stretch));
    let long = make(max_depth);
    let mut d = min_depth;
    while d <= max_depth {
        let iters = 1i64 << (max_depth - d + min_depth);
        let mut c = 0;
        for _ in 0..iters { c += check(&make(d)); }
        println!("{}", c);
        d += 2;
    }
    println!("{}", check(&long));
}
