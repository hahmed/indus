struct Request { path: String, params: Vec<i64> }
impl Request {
    fn new(id: i64) -> Request { let mut p = vec![0i64; 4]; p[0] = id; p[1] = id * 2; Request { path: format!("/items/{}", id), params: p } }
    fn checksum(&self) -> i64 { self.path.len() as i64 + self.params[0] + self.params[1] }
}
fn main() {
    let mut kept: Vec<Request> = Vec::new(); let mut total = 0i64;
    for i in 0..400000i64 { let r = Request::new(i); total += r.checksum(); if i % 500 == 0 { kept.push(r); } }
    println!("{}", total); println!("{}", kept.len());
    let s: i64 = kept.iter().map(|r| r.checksum()).sum(); println!("{}", s); println!("{}", kept[300].path);
}
