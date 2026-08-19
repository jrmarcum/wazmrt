//! wazmrt — a fast, tiny WebAssembly runtime.
//!
//! This is the public library surface. It is dependency-free and compiles for
//! native targets as well as `wasm32-freestanding`, so wazmrt can host wasm on
//! a machine or be embedded *inside* another wasm host.

const std = @import("std");

/// Comptime feature gates (Track 2c). Supplied per ARTIFACT by `build.zig`, not
/// globally: `-Dwat=false` / `-Dwasi=false` strip the WAT assembler and the WASI
/// host from the **embed** artifacts (the C-ABI static lib, the DLL, the
/// freestanding wasm), while the CLI and the test/conformance targets always
/// build with both on.
///
/// ⚠️ **This is NOT a descope of `.wat`** (owner, 2026-08-11). Running text is a
/// stated capability and the CLI keeps it unconditionally; the flag exists only
/// so an embedder who never assembles text does not have to carry the assembler.
/// The measured reason it exists at all: replacing the wasm-c-api surface took
/// the DLL from 227 KB to 845 KB because the embed artifact now carries
/// `wat.zig` + `sexpr.zig`, `wasi.zig` and an `Io`.
///
/// ⚠️ **A disabled feature is REJECTED LOUDLY, never silently ignored** — the
/// canonical fall-through failure mode this codebase refuses elsewhere. See
/// `capi.zig`'s `wazmrt_module_new_wat` / `wazmrt_wat_to_wasm` /
/// `wazmrt_linker_define_wasi`, which return a real error explaining the build
/// flag rather than a null module or a no-op linker.
const config = @import("wazmrt_config");
pub const enable_wat = config.enable_wat;
pub const enable_wasi = config.enable_wasi;

pub const types = @import("types.zig");
pub const Reader = @import("Reader.zig");
pub const Module = @import("Module.zig");
pub const opcode = @import("opcode.zig");
pub const validate = @import("validate.zig").validate;
/// `validate`, judged by a specific proposal ERA — **and the only entry point that gates**.
/// The feature check lives INSIDE it (F1r), so an embedder's restricted set filters which
/// proposals may appear *and* selects the typing rules that go with them. `validate` is this
/// with the all-features default, which short-circuits the gate entirely.
pub const validateWith = @import("validate.zig").validateWith;
/// Where the last `validate` failure was and what it was about — see `FailureSite`. A side channel
/// because a Zig error set carries no payload, so `error.TypeMismatch` alone cannot say which types.
pub const lastFailureSite = @import("validate.zig").lastFailureSite;
pub const FailureSite = @import("validate.zig").FailureSite;
pub const interp = @import("interp.zig");
/// Type identity and import matching ACROSS module boundaries — a concrete
/// `(ref $t)` carries a module-local index, so linking two modules cannot compare
/// value types directly. Any linker that binds one module's export to another's
/// import must go through this.
pub const typematch = @import("typematch.zig");
/// Per-proposal gating: which WebAssembly proposals a module is allowed to use.
pub const features = @import("features.zig");
pub const Instance = interp.Instance;
// The text toolchain is one unit: `wast` needs `wat`, `wat` needs `sexpr`.
// Gating them to an empty struct rather than omitting the declaration keeps
// `root.wat` a compile error about a MISSING DECL only where it is genuinely
// used, and lets `capi.zig` test `root.enable_wat` without conditional imports.
pub const sexpr = if (enable_wat) @import("sexpr.zig") else struct {};
pub const wat = if (enable_wat) @import("wat.zig") else struct {};
pub const wast = if (enable_wat) @import("wast.zig") else struct {};
pub const wasi = if (enable_wasi) @import("wasi.zig") else struct {};
pub const pin = @import("pin.zig");
pub const sign = @import("sign.zig");

/// Human-readable library version (keep in sync with build.zig.zon).
pub const version: [:0]const u8 = "1.0.1";

/// Stable C-ABI version for embedders (universalWasmLoader-*). Bump on any
/// breaking change to the exported C symbols.
///
/// **2 = the native `wazmrt.h` surface.** Version 1 was the vendored wasm-c-api (`wasm_*`
/// symbols); nothing from it survives, so a v1 consumer fails to LINK rather than mislinking.
/// The number exists for consumers that bind dynamically and only check it.
pub const abi_version: u32 = 2;

/// Decode a WebAssembly binary into a `Module`. Caller owns the result and
/// must call `Module.deinit`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Module.Error!Module {
    return Module.decode(allocator, bytes);
}

test {
    // Pull in the tests declared across the core modules.
    std.testing.refAllDecls(@This());
    _ = Reader;
    _ = Module;
    _ = opcode;
    _ = @import("validate.zig");
    _ = interp;
    _ = pin;
    _ = sign;
    // The text toolchain and its fuzz targets exist only in a `-Dwat` build. The
    // test/conformance targets always set it, so this is never skipped in
    // practice — the condition is here so a `-Dwat=false` build still compiles
    // its own tests rather than failing on a missing decl.
    if (enable_wat) {
        _ = sexpr;
        _ = wat;
        _ = wast;
        _ = @import("fuzz.zig"); // malformed-input fuzz targets (see fuzz.zig)
    }
}
