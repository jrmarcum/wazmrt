// Compiled-program conformance guest (Rust).
// Built with `rustc --target wasm32-wasip1` and run through the wazmrt CLI by
// `zig build wasi-gate -Drust-gate=true` (opt-in: needs a rustc with the
// wasm32-wasip1 target). A genuinely different compiler than Zig/clang — the
// strongest cross-toolchain conformance signal. Expected stdout is in build.zig.
fn main() {
    println!("Hello from Rust on wazmrt!");
    let v: Vec<i32> = (1..=5).map(|x| x * x).collect();
    println!("sum of squares 1..5 = {}", v.iter().sum::<i32>());
}
