struct Row { name: String, qty: i64 }
impl Row { fn line(&self) -> String { format!("{}: {} units", self.name, self.qty) } }
fn main() {
    let rows: Vec<Row> = (0..100i64).map(|i| Row { name: format!("item{}", i), qty: i * 3 }).collect();
    let (mut total, mut hits) = (0usize, 0i64);
    for _ in 0..2000 {
        let mut out = String::new();
        for j in 0..100 { let l = rows[j].line(); out.push_str(&l); out.push('\n'); if l == "item7: 21 units" { hits += 1; } }
        total += out.len();
    }
    println!("{}", total); println!("{}", hits); println!("{}", rows[7].line());
}
