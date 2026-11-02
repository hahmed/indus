use std::collections::HashMap;
fn main() {
    let words = ["the","of","and","to","in","a","is","that","for","it","was","on","are","be","with","as","at","by","this","from"];
    let n = 10000; let mut result: Vec<&str> = Vec::with_capacity(n); let mut seed: i64 = 42;
    for _ in 0..n { seed = (seed * 1103515245 + 12345) % 2147483648; result.push(words[(seed / 107374182) as usize]); }
    let mut freq: HashMap<&str, i64> = HashMap::new();
    for w in &result { if freq.contains_key(w) { *freq.get_mut(w).unwrap() += 1; } else { freq.insert(w, 1); } }
    let keys: Vec<&&str> = freq.keys().collect();
    let mut total = 0i64; for k in &keys { total += freq[*k]; }
    println!("{}", total); println!("{}", keys.len());
}
