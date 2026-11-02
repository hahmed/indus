fn main() { let mut sum = 0i64; let mut i = 1i64; while i <= 500000000 { sum += i % 7; i += 1; } println!("{}", sum); }
