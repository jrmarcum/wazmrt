// Compiled-program conformance guest (C).
// Built with `zig cc -target wasm32-wasi` and run through the wazmrt CLI by the
// `zig build wasi-gate` step. Exercises the C/wasi-libc ABI surface (printf →
// fd_write via WASI) end to end. Expected stdout is asserted in build.zig.
#include <stdio.h>

int main(void) {
    printf("Hello from C on wazmrt!\n");
    long acc = 0;
    for (int i = 1; i <= 100; i++) acc += i;
    printf("sum 1..100 = %ld\n", acc);
    return 0;
}
