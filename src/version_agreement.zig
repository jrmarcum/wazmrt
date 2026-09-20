//! The version string, pinned everywhere it is copied.
//!
//! 🔢 `cmem/releasing.md` lists four places the number lives and says plainly that **no test asserts
//! they agree**, so a bump has been a grep every time — and it names adding this test as a legitimate
//! Track B finding. 🎓 *A rule nobody has watched fail is not enforcement*: the same argument that
//! turned `abi_version` into a real gate, applied to the number beside it.
//!
//! ⚠️ The copies are not cosmetic. `build.zig.zon`'s is what a package consumer resolves, and the
//! header's is what an embedder reads to decide which surface they are compiling against.
//!
//! 📎 **Why this is its own file and its own test target.** The check needs `@embedFile` on two files
//! outside `src/`, which means the module has to carry anonymous imports for them. `root.zig` is
//! compiled into six different modules (the library, the C ABI tests, and the ReleaseSafe and
//! ReleaseSmall variants of both), so putting it there would mean wiring those imports into every
//! one of them and re-wiring on every future target. One file, one module, one place to wire.
//!
//! 🔒 It runs under `zig build test` and not under `test-safe` / `test-shipped`, deliberately: the
//! claim is about SOURCE FILES agreeing with each other, which no optimize mode can change. Running
//! it three times would cost build time to re-establish the same fact.

const std = @import("std");
const wazmrt = @import("wazmrt");

test "the version string agrees in every place it is copied" {
    var buf: [64]u8 = undefined;
    const quoted = try std.fmt.bufPrint(&buf, "\"{s}\"", .{wazmrt.version});

    // The package manifest: `.version = "x.y.z",`.
    const manifest = @embedFile("project_manifest");
    if (std.mem.indexOf(u8, manifest, quoted) == null) {
        std.debug.print("\nbuild.zig.zon does not contain {s} (root.version)\n", .{quoted});
        return error.VersionDriftInManifest;
    }

    // The public header's example on `wazmrt_version_string`. Cosmetic to the compiler and
    // load-bearing to a human, which is exactly the combination that drifts.
    const header = @embedFile("project_header");
    if (std.mem.indexOf(u8, header, quoted) == null) {
        std.debug.print("\ninclude/wazmrt.h does not contain {s} (root.version)\n", .{quoted});
        return error.VersionDriftInHeader;
    }

    // ⬜ The fourth copy — `cmem/overview.md`'s tree annotation — is deliberately NOT pinned.
    // It is project memory rather than public surface, and reaching into `cmem/` from `src/`
    // would make renaming a memory document a compile error in the runtime. It stays a grep,
    // and `releasing.md` step 9 is where that is recorded.
}

test "the ABI version is a number the header and the library agree on" {
    // `abi_version` already had a real gate (`tests/wazmrt_abi_symbols.c` links against it), but the
    // HEADER's own `#define` was never compared with the Zig constant — the same shape as the
    // version-string drift, one field over.
    var buf: [64]u8 = undefined;
    const expect = try std.fmt.bufPrint(&buf, "{d}", .{wazmrt.abi_version});
    const header = @embedFile("project_header");
    // ⚠️ The `#define`, not the bare name: `WAZMRT_ABI_VERSION` is mentioned twice in PROSE above
    // the declaration, and a first-match search read one of those comment lines and reported drift
    // that did not exist. *A search for an identifier in a C header will find the documentation
    // before it finds the definition.*
    const at = std.mem.indexOf(u8, header, "#define WAZMRT_ABI_VERSION") orelse {
        std.debug.print("\ninclude/wazmrt.h has no `#define WAZMRT_ABI_VERSION` to compare against\n", .{});
        return error.AbiVersionNotInHeader;
    };
    // Read the rest of that line and require the number to appear on it.
    const line_end = std.mem.indexOfScalarPos(u8, header, at, '\n') orelse header.len;
    if (std.mem.indexOf(u8, header[at..line_end], expect) == null) {
        std.debug.print("\ninclude/wazmrt.h's WAZMRT_ABI_VERSION line does not say {s}\n", .{expect});
        return error.AbiVersionDrift;
    }
}
