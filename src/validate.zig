//! Type validation of a decoded module (WebAssembly spec §3, using the
//! Appendix "Validation Algorithm": an abstract operand-value stack + a
//! control-frame stack, with a bottom `unknown` type for stack-polymorphic /
//! unreachable code).
//!
//! Scope matches the decoder: the core-MVP instruction set. It checks the
//! function/code count match (deferred from decode), local/global/func/type
//! index bounds, structured control flow, operand-stack typing, and — since
//! 2026-07-21 — that every memory-touching op names an **in-range** memory
//! (scalar loads/stores, SIMD loads/stores, `memory.size`/`grow`) plus
//! load/store alignment. (This header previously said memory presence and
//! alignment were "not yet enforced"; that leniency is gone.)
//!
//! `validate` does not mutate the module; it decodes each body to IR in a scratch
//! arena and type-checks it. It is also a **C-ABI entry point**
//! (`wasm_module_validate`), so "the validator accepted it" is a promise to an
//! embedder, not just a developer convenience — see `cmem/design-decisions.md`.
//!
//! Resource caps live here too (`max_ctrl_depth`, `max_locals`): a tiny module
//! could otherwise drive gigabytes of validator state. **Their cost is a
//! product** — read both before changing either.

const std = @import("std");
const types = @import("types.zig");
const Module = @import("Module.zig");
const opcode = @import("opcode.zig");
const Reader = @import("Reader.zig");

const V = types.ValType;
const Op = opcode.Op;

/// Cap on control nesting. Every `pushCtrl` snapshots the whole local-init
/// vector, so cost is depth × locals: a 512 KB module (2 000 locals, 262 144
/// nested blocks) drove **767 MB** peak — ~1500× amplification — on the inspect
/// path. Real code nests a few dozen deep; 1024 also matches `sexpr.zig`'s
/// parser cap, so nothing reachable from `.wat`/`.wast` text can exceed it.
const max_ctrl_depth: usize = 1024;

/// Cap on a function's locals (params + declared). The binary run-length form
/// (`count: u32` per run) lets a handful of bytes ask for billions.
///
/// This and `max_ctrl_depth` must be read together: the snapshot cost is their
/// **product**, so a generous locals cap silently reinstates the amplification
/// (2^20 locals × 1024 frames would still be ~1 GB). 50 000 — matching
/// wasmtime's own default — bounds the worst case at ~51 MB while staying far
/// above anything a compiler emits.
pub const max_locals: u64 = 50_000;

pub const Error = Module.Error || error{
    CountMismatch,
    TypeMismatch,
    StackUnderflow,
    StackHeightMismatch,
    ControlUnderflow,
    UnknownLabel,
    MismatchedElse,
    /// A legacy `catch`/`catch_all`/`delegate` whose enclosing opener is not a
    /// legacy `try` (older-LLVM exception handling).
    MismatchedCatch,
    UndefinedLocal,
    /// A `local.get` of a non-defaultable (non-nullable ref) local before it was
    /// set (function-references local initialization, §3.3.5).
    UninitializedLocal,
    /// Control nesting exceeded `max_ctrl_depth`. Each frame snapshots the whole
    /// local-init vector, so depth × locals is a memory amplifier: a 512 KB
    /// module (2 000 locals, 262 144 nested blocks) drove **767 MB** peak before
    /// this cap.
    NestingTooDeep,
    /// A function declared more than `max_locals` locals. The run-length local
    /// encoding lets a handful of bytes ask for billions.
    TooManyLocals,
    UndefinedGlobal,
    ImmutableGlobal,
    UndefinedFunc,
    /// `ref.func x` in a function body where `x` is not in C.refs — the function
    /// exists, but nothing outside the code section declares it (§3.4.10,
    /// "undeclared function reference"). Add `(elem declare func $x)`.
    UndeclaredFuncRef,
    UndefinedType,
    /// A `throw`/catch tag index out of range (EH proposal).
    UndefinedTag,
    /// A tag whose type produces results (tags must have empty results).
    InvalidTag,
    /// A memory/table limits pair violates §3.2.5 — `min > max`, or a bound past
    /// the type ceiling (2^16 pages for a memory).
    InvalidLimits,
    /// Two exports share a name (§3.4.10 requires them pairwise distinct).
    DuplicateExport,
    UndefinedTable,
    UndefinedElem,
    /// A `memory.init`/`data.drop` data-segment index out of range.
    UndefinedData,
    /// A `(type $s (sub $t …))` whose declared supertype is not a real one —
    /// `$t` is final, a different composite kind, or structurally incompatible
    /// (§3.3.9). Left unchecked, `isSubtype` believes it and `ref.cast` succeeds
    /// on a value that does not have the target type.
    InvalidSubtype,
    /// A legacy `rethrow l` whose label is not a `catch`/`catch_all` block.
    /// Nothing else binds a caught exception, so there is nothing to re-raise.
    InvalidRethrowLabel,
    /// `memory.init`/`data.drop` appeared in a module with no data-count section.
    /// §5.5.16 makes that section mandatory once either instruction is used —
    /// a single-pass decoder has to know the segment count before the code
    /// section, so its absence is malformed even though the indices resolve.
    DataCountRequired,
    /// A struct/array field index out of range for its type (GC).
    UndefinedField,
    /// A `struct.set`/`array.set` on an immutable field (GC).
    ImmutableField,
    /// `struct.get`/`array.get` on a packed field (must use `_s`/`_u`), or the
    /// `_s`/`_u` form on an unpacked field (GC).
    BadFieldPacking,
    InvalidStartFunction,
    ConstantExpressionRequired,
    InvalidAlignment,
    MissingMemory,
    /// A memarg static offset >= 2^32 on a 32-bit memory. The decoder reads the
    /// offset as `u64` (memory64), so this ceiling — which only a 64-bit memory
    /// may exceed — is a validation rule.
    InvalidMemArgOffset,
};

/// Where the last validation failure was, and what it was about.
///
/// **A side channel because a Zig error set cannot carry a payload** — `error.TypeMismatch` is a bare
/// tag, so "expected i32, found i64" has nowhere to live on the error itself. (The Rust port reached
/// the same design for a different reason: its `ValidateError` *could* carry data, but it is `Copy`,
/// exhaustively matched, and crosses a C ABI.)
///
/// **Shaped to match wasmtime**, which is the standard for diagnostics as well as behaviour.
/// wasmtime 47 on `(func (result i32) i64.const 1)`:
///
/// ```text
/// Invalid input WebAssembly code at offset 33: type mismatch: expected i32, found i64
/// ```
///
/// `threadlocal` so two threads validating at once cannot scramble each other's report. A stale value
/// can only mislabel a *later* failure, never make a success look like one, because `validate` clears
/// this on entry.
pub const FailureSite = struct {
    /// Index in the function index space (imports included), if the failure was inside a body.
    func_index: ?u32 = null,
    /// Byte offset from the start of the module of the instruction that failed — the same number,
    /// and the same origin, that wasmtime prints.
    offset: ?u32 = null,
    /// For a type mismatch: what the instruction required, and what was on the stack.
    expected: ?V = null,
    found: ?V = null,
};

threadlocal var site: FailureSite = .{};

/// Everything known about the most recent [`validate`] failure. Valid until the next `validate` call
/// on this thread; all-null after a success.
pub fn lastFailureSite() FailureSite {
    return site;
}

/// Validate an entire module. Returns on the first error.
pub fn validate(gpa: std.mem.Allocator, module: *const Module) Error!void {
    // Cleared on ENTRY, not on success: a module-level failure below must report "no location"
    // rather than inherit the previous module's.
    site = .{};

    if (module.functions.len != module.code.len) return error.CountMismatch;

    // Every DECLARED supertype must actually be one (§3.3.9). This has to run
    // before anything consults `isSubtype`, which simply trusts the chain — so
    // an unchecked declaration turns `ref.cast` into a lie the interpreter then
    // acts on.
    for (module.supertypes, 0..) |maybe_sup, i| if (maybe_sup) |sup|
        if (!declaredSubtypeOk(module, @intCast(i), sup)) return error.InvalidSubtype;

    // C.refs (§3.4.10, "undeclared function reference"): `ref.func x` inside a
    // FUNCTION BODY is well-typed only if `x` also occurs somewhere *outside*
    // the code section — a global initializer, an element segment, or an export.
    // That rule is why `(elem declare func $f)` exists: it is the way to admit a
    // reference to a function nothing else mentions.
    //
    // ⚠️ **The START function does NOT declare one**, and both this code and the
    // comment above it used to say it did. §3.5.1 builds `C.refs` from
    // `funcidx(module with funcs = ε with start = ε)` — the start index is
    // explicitly erased along with the function section, precisely so that
    // "the module runs it" does not double as "the module may take its address".
    // `ref_func.wast` pins it: `(module (start $f) (func $f (drop (ref.func $f))))`
    // is invalid, and we accepted it. A rule written into a comment is not
    // evidence the rule exists.
    //
    // Populated below as the module-level structures are walked, then consulted
    // by the body validator's `.ref_func` arm. Sized over the whole function
    // index space (imports first, then defined) so a raw funcidx indexes it.
    const n_funcs = module.importedFuncCount() + module.functions.len;
    var refs = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_funcs);
    defer refs.deinit(gpa);
    for (module.exports) |e| if (e.type.kind() == .func and e.index < n_funcs) refs.set(e.index);

    // Global init const-exprs: each must be a constant expression producing
    // exactly the declared type. Defined globals occupy the tail of the space.
    const n_imported_globals: u32 = @intCast(module.globals.len - module.global_inits.len);
    for (module.global_inits, 0..) |init_expr, i| {
        const self_index = n_imported_globals + @as(u32, @intCast(i));
        try validateConstExpr(module, init_expr, module.globals[self_index].content, self_index, &refs);
    }

    // Active-segment *offset* const-exprs may reference any immutable global —
    // imported or defined (globals precede the element/data sections). But the
    // ref-producing *element expressions* (and table initializers, lowered to
    // them) follow the stricter rule of referencing only imported globals, so a
    // `global.get` of a defined global there is rejected as "unknown global".
    const all_globals: u32 = @intCast(module.globals.len);

    // Element segments: every referenced function index must exist; each
    // element const-expr must produce the segment's element type; an active
    // segment targets an existing type-compatible table with a valid i32 offset.
    for (module.elements) |elem| {
        for (elem.funcs) |fi| {
            if (module.funcType(fi) == null) return error.UndefinedFunc;
            if (fi < n_funcs) refs.set(fi); // a segment entry declares the function
        }
        // ⚠️ **`all_globals`, not `n_imported_globals`.** §3.5.13 validates the
        // element segments under the FULL context `C`; only `global*` uses the
        // restricted `C'` that holds imported globals alone (line 202 above, where
        // the bound is the global's own index so an initializer sees only PRIOR
        // globals). Passing the restricted bound here rejected
        // `(elem (table $t) … (global.get $gf))` for a DEFINED `$gf` — a valid
        // module, and the whole of `global.wast`'s last module with it. The
        // element expressions of an active segment are evaluated in
        // `applyActiveSegments`, after every global is initialized, so the value
        // is genuinely available. The segment OFFSET (line ~252) already used the
        // full bound; only the element expressions kept the old restriction.
        for (elem.exprs) |ex| try validateConstExpr(module, ex, elem.elem_type, all_globals, &refs);
        if (elem.mode == .active) {
            if (elem.table_index >= module.tables.len) return error.UndefinedTable;
            const tet = module.tables[elem.table_index].element;
            // §3.5.11: the segment's element type must be a SUBTYPE of the
            // table's — the same rule `table.init` already used below.
            //
            // ⚠️ This was a nullability-normalized EQUALITY check. A 10th-pass
            // audit called it an accept-invalid bug on the theory that
            // `ValType.nullable()` was a predicate; that theory was wrong and the
            // finding was retracted with a "don't fix it again" note. The
            // mechanism was indeed as the retraction described — and the RULE was
            // still wrong. Normalizing nullability away accepts a `funcref`
            // segment into a `(ref func)` table, which `elem.wast` requires to be
            // rejected: it would put nulls in a table whose type promises none.
            // A retraction that only checks the reasoning does not re-check the
            // requirement.
            if (!subtypeOf(module, elem.elem_type, tet)) return error.TypeMismatch;
            // The active-elem offset has the target TABLE's index type, exactly
            // as an active-data offset takes its memory's (table64).
            const off_ty: V = if (module.tables[elem.table_index].limits.is64) .i64 else .i32;
            try validateConstExpr(module, elem.offset_expr, off_ty, all_globals, null);
        }
    }

    // Data segments: an active segment targets an existing memory (only memory 0
    // is supported) and its offset const-expr must produce an i32.
    for (module.data) |seg| {
        if (!seg.active) continue;
        if (seg.mem_index >= module.memories.len) return error.MissingMemory;
        // The active-data offset has the target memory's index type (memory64).
        const off_ty: V = if (module.memories[seg.mem_index].limits.is64) .i64 else .i32;
        try validateConstExpr(module, seg.offset_expr, off_ty, all_globals, null);
    }

    // Limits (§3.2.5): `min <= max`, and each is bounded by the type's ceiling —
    // 2^16 pages for a memory, 2^32-1 entries for a table. Neither half was
    // checked, so `(memory 5 2)` and `(memory 70000)` both validated. Contained
    // at run time (instantiation clamps and the `--max-memory` budget refuses),
    // but the validator is a C-ABI entry point and should say so itself.
    for (module.memories) |mt| {
        // Page-count ceiling: 2^16 for a 32-bit memory, 2^48 for a 64-bit one
        // (memory64). A shared memory must declare a max (§ threads).
        const ceiling: u64 = if (mt.limits.is64) 0x1_0000_0000_0000 else 0x1_0000;
        if (mt.limits.min > ceiling) return error.InvalidLimits;
        if (mt.limits.max) |mx| {
            if (mx > ceiling or mt.limits.min > mx) return error.InvalidLimits;
        } else if (mt.limits.shared) return error.InvalidLimits;
    }
    for (module.tables) |tt| {
        // Entry-count ceiling: 2^32-1 for a 32-bit table, 2^64-1 for a 64-bit one
        // (table64) — which every u64 satisfies, so only the 32-bit case bounds.
        if (!tt.limits.is64) {
            if (tt.limits.min > 0xffff_ffff) return error.InvalidLimits;
            if (tt.limits.max) |mx| if (mx > 0xffff_ffff) return error.InvalidLimits;
        }
        if (tt.limits.max) |mx| {
            if (tt.limits.min > mx) return error.InvalidLimits;
        }
        // §3.2.4 + function-references: a table's element type must be
        // DEFAULTABLE, unless the table supplies an explicit initializer
        // (§5.5.6's `0x40` form). A non-nullable reference has no default value,
        // so `(table 0 (ref func))` describes a table whose slots cannot be given
        // a starting state — and the size does not save it: `table.grow` would
        // still have to invent one, which is why even a 0-length table is invalid.
        //
        // ⚠️ Neither half of this existed. The rule was unchecked here, AND the
        // initializer that exempts a table from it was never validated at all: a
        // `0x40`-form table could name any const-expr of any type and only the
        // INTERPRETER would find out, at instantiation. `table.wast` pins six
        // modules on the first half.
        if (tt.init_expr) |ie| {
            try validateConstExpr(module, ie, tt.element, n_imported_globals, &refs);
        } else if (tt.element.isNonNullRef()) {
            return error.TypeMismatch;
        }
    }

    // Tag types (§3.2, EH): a tag's type must be `[t1*] → []`. `throw` checked
    // this at its use site but the TAG SECTION ITSELF was never walked, so a
    // module declaring `(tag (type $ft))` with a result-producing `$ft`
    // validated — and could be exported or imported.
    //
    // ⚠️ `module.tags` is the DEFINED tags only — imported tags lead the index
    // space and are not in that slice — so the fix above checked exactly half the
    // tags and `(import "" "" (tag (result i32)))` still validated. Walk the whole
    // index space through `tagType`, which is the accessor that knows the layout.
    // Same shape as the ref-identity work: **when a space has imported and defined
    // halves, a loop over the defined slice is not a loop over the space.**
    const n_tags = module.importedTagCount() + module.tags.len;
    var ti: u32 = 0;
    while (ti < n_tags) : (ti += 1) {
        const ft = module.tagType(ti) orelse return error.UndefinedType;
        if (ft.results.len != 0) return error.InvalidTag;
    }

    // Export names must be pairwise distinct (§3.4.10). Linear scan: export
    // counts are small, and this avoids an allocation on the validate path.
    for (module.exports, 0..) |e, i| {
        for (module.exports[i + 1 ..]) |o| {
            if (std.mem.eql(u8, e.name, o.name)) return error.DuplicateExport;
        }
    }

    // Start function (§3.5.5): must be a defined/imported function of type [] → [].
    if (module.start) |si| {
        const ft = module.funcType(si) orelse return error.UndefinedFunc;
        if (ft.params.len != 0 or ft.results.len != 0) return error.InvalidStartFunction;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const imported = module.importedFuncCount();
    for (module.functions, module.code, 0..) |type_index, code, n| {
        const ft = module.funcSig(type_index) orelse return error.UndefinedType;
        validateFunction(arena.allocator(), module, ft, code, null, &refs) catch |e| {
            // Locate the failure for the diagnostic. `validateFunction` leaves `site.pc_hint` at the
            // instruction it stopped on; mapping that to a byte offset costs a re-decode of this one
            // body, which is fine because it happens **only on failure** — the same cold-path trick
            // `Instance.frameOffset` uses for trap frames, and the reason no offset is stored per
            // instruction. (The Rust port instead keeps a `u32` on `Instr`, free in its padding.)
            site.func_index = imported + @as(u32, @intCast(n));
            site.offset = offsetOfPc(arena.allocator(), code, pc_hint);
            return e;
        };
        _ = arena.reset(.retain_capacity);
    }
}

/// Instruction index within the body that validation stopped on. Set by the per-instruction loop and
/// read only when that loop fails, so it costs one store per instruction and nothing else.
threadlocal var pc_hint: usize = 0;

/// Map an instruction index in `code` to its absolute module offset, or null if the body will not
/// re-decode. Cold path only.
fn offsetOfPc(a: std.mem.Allocator, code: Module.Code, pc: usize) ?u32 {
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(a);
    const ir = opcode.decodeBodyTracked(a, code.body, &offsets) catch return null;
    opcode.freeBody(a, ir); // we want the offsets, not the IR
    if (pc >= offsets.items.len) return null;
    return code.body_offset + offsets.items[pc];
}

/// Type-check a constant expression (§3.3.7 + extended-const `i32`/`i64`
/// `add`/`sub`/`mul`). It must produce exactly one value of `expected`. A
/// `global.get x` may reference only a *prior* (`x < self_index`) *immutable*
/// global; anything outside the const-expr opcode set is rejected.
fn validateConstExpr(module: *const Module, expr: []const u8, expected: V, self_index: u32, refs: ?*std.DynamicBitSetUnmanaged) Error!void {
    var r = Reader.init(expr);
    var stack: [8]V = undefined;
    var sp: usize = 0;
    const push = struct {
        fn f(s: *[8]V, p: *usize, t: V) Error!void {
            if (p.* >= s.len) return error.ConstantExpressionRequired;
            s[p.*] = t;
            p.* += 1;
        }
    }.f;
    while (true) {
        const op = try r.readByte();
        switch (op) {
            0x0b => break, // end
            0x41 => {
                _ = try r.readVarI32();
                try push(&stack, &sp, .i32);
            },
            0x42 => {
                _ = try r.readVarI64();
                try push(&stack, &sp, .i64);
            },
            0x43 => {
                _ = try r.readBytes(4);
                try push(&stack, &sp, .f32);
            },
            0x44 => {
                _ = try r.readBytes(8);
                try push(&stack, &sp, .f64);
            },
            0xfd => { // SIMD prefix — `v128.const` (sub 0x0c) is a constant expression
                // §3.3.7 lists `v128.const` among the constant instructions, but
                // this arm did not exist, so EVERY `(global v128 (v128.const …))`
                // was rejected `ConstantExpressionRequired` — a reject-VALID on a
                // form LLVM emits for any module with a SIMD global. It hid
                // behind the CLI's invoke path, which does not validate.
                const sub = try r.readVarU32();
                if (sub != 0x0c) return error.ConstantExpressionRequired;
                _ = try r.readBytes(16); // the 16 immediate lane bytes
                try push(&stack, &sp, .v128);
            },
            0x23 => { // global.get x — only a prior, immutable global
                const gi = try r.readVarU32();
                if (gi >= self_index) return error.UndefinedGlobal;
                if (module.globals[gi].mutable) return error.ConstantExpressionRequired;
                try push(&stack, &sp, module.globals[gi].content);
            },
            0xd0 => { // ref.null <heaptype>
                const heap = opcode.readHeapType(&r) catch return error.ConstantExpressionRequired;
                try push(&stack, &sp, try refTypeValType(module, .{ .nullable = true, .heap = heap }));
            },
            0xd2 => { // ref.func x
                const fi = try r.readVarU32();
                if (module.funcType(fi) == null) return error.UndefinedFunc;
                // A `ref.func` outside the code section DECLARES that function
                // (C.refs), which is what makes it referenceable from a body.
                if (refs) |set| if (fi < set.bit_length) set.set(fi);
                // Concrete `(ref $ftype)` for a defined func; abstract for imports.
                if (module.funcTypeIndex(fi)) |ti|
                    try push(&stack, &sp, V.concreteRef(false, .func, ti))
                else
                    try push(&stack, &sp, .funcref_nn);
            },
            0x6a, 0x6b, 0x6c => { // i32 add/sub/mul (extended-const)
                if (sp < 2 or stack[sp - 1] != .i32 or stack[sp - 2] != .i32) return error.TypeMismatch;
                sp -= 1;
            },
            0x7c, 0x7d, 0x7e => { // i64 add/sub/mul (extended-const)
                if (sp < 2 or stack[sp - 1] != .i64 or stack[sp - 2] != .i64) return error.TypeMismatch;
                sp -= 1;
            },
            0xfb => { // GC constant instructions (§3.3.7 + GC proposal)
                const sub = try r.readVarU32();
                switch (sub) {
                    0x1c => { // ref.i31
                        if (sp < 1 or stack[sp - 1] != .i32) return error.TypeMismatch;
                        stack[sp - 1] = .i31ref_nn;
                    },
                    0x00 => { // struct.new $t — pop each field (reverse), push (ref $t)
                        const ti = try r.readVarU32();
                        const fields = module.structFields(ti) orelse return error.UndefinedType;
                        if (sp < fields.len) return error.TypeMismatch;
                        var i = fields.len;
                        while (i > 0) {
                            i -= 1;
                            sp -= 1;
                            if (!subtypeOf(module, stack[sp], fields[i].storage.unpacked())) return error.TypeMismatch;
                        }
                        try push(&stack, &sp, V.concreteRef(false, .@"struct", ti));
                    },
                    0x01 => { // struct.new_default $t — every field must be defaultable
                        const ti = try r.readVarU32();
                        const fields = module.structFields(ti) orelse return error.UndefinedType;
                        for (fields) |f| if (f.storage.unpacked().isNonNullRef()) return error.TypeMismatch;
                        try push(&stack, &sp, V.concreteRef(false, .@"struct", ti));
                    },
                    0x06 => { // array.new $t — operands (elem, size); size on top
                        const ti = try r.readVarU32();
                        const f = module.arrayField(ti) orelse return error.UndefinedType;
                        if (sp < 2 or stack[sp - 1] != .i32) return error.TypeMismatch;
                        sp -= 1;
                        if (!subtypeOf(module, stack[sp - 1], f.storage.unpacked())) return error.TypeMismatch;
                        stack[sp - 1] = V.concreteRef(false, .array, ti);
                    },
                    0x07 => { // array.new_default $t — element must be defaultable
                        const ti = try r.readVarU32();
                        const f = module.arrayField(ti) orelse return error.UndefinedType;
                        if (f.storage.unpacked().isNonNullRef()) return error.TypeMismatch;
                        if (sp < 1 or stack[sp - 1] != .i32) return error.TypeMismatch;
                        stack[sp - 1] = V.concreteRef(false, .array, ti);
                    },
                    0x08 => { // array.new_fixed $t N — pop N elements (reverse)
                        const ti = try r.readVarU32();
                        const n = try r.readVarU32();
                        const f = module.arrayField(ti) orelse return error.UndefinedType;
                        if (sp < n) return error.TypeMismatch;
                        var k = n;
                        while (k > 0) {
                            k -= 1;
                            sp -= 1;
                            if (!subtypeOf(module, stack[sp], f.storage.unpacked())) return error.TypeMismatch;
                        }
                        try push(&stack, &sp, V.concreteRef(false, .array, ti));
                    },
                    0x1a => { // extern.convert_any : (ref null? any) → (ref null? extern)
                        if (sp < 1 or !stack[sp - 1].isRef()) return error.TypeMismatch;
                        stack[sp - 1] = if (stack[sp - 1].isNonNullRef()) .externref_nn else .externref;
                    },
                    0x1b => { // any.convert_extern : (ref null? extern) → (ref null? any)
                        if (sp < 1 or !stack[sp - 1].isRef()) return error.TypeMismatch;
                        stack[sp - 1] = if (stack[sp - 1].isNonNullRef()) .anyref_nn else .anyref;
                    },
                    else => return error.ConstantExpressionRequired,
                }
            },
            else => return error.ConstantExpressionRequired,
        }
    }
    if (sp != 1 or !subtypeOf(module, stack[0], expected)) return error.TypeMismatch;
}

fn validateFunction(a: std.mem.Allocator, module: *const Module, ft: Module.FuncType, code: Module.Code, widths: ?[]u8, refs: ?*const std.DynamicBitSetUnmanaged) Error!void {
    // locals = parameters ++ declared locals (expanded from run-length form).
    var locals: std.ArrayList(V) = .empty;
    try locals.appendSlice(a, ft.params);
    // The run-length form means a few bytes can ask for billions of locals, and
    // the old loop appended them one at a time — multi-GB from a tiny module.
    // Sum first (checked), reject past the cap, then expand.
    var declared: u64 = 0;
    for (code.locals) |l| declared += l.count;
    if (declared + ft.params.len > max_locals) return error.TooManyLocals;
    for (code.locals) |l| {
        var n = l.count;
        while (n > 0) : (n -= 1) try locals.append(a, l.type);
    }

    const instrs = try opcode.decodeBody(a, code.body);

    // Local-init: parameters are always initialized; a *declared* defaultable
    // local starts initialized, but a non-nullable-ref one is non-defaultable and
    // starts uninitialized.
    const n_params = ft.params.len;
    const local_init = try a.alloc(bool, locals.items.len);
    for (local_init, locals.items, 0..) |*init, t, i| init.* = i < n_params or !t.isNonNullRef();

    var v: FuncValidator = .{ .a = a, .module = module, .refs = refs, .locals = locals.items, .results = ft.results, .local_init = local_init, .widths = widths, .body_len = instrs.len };
    // The whole body is an implicit block of type [] -> results; its trailing
    // `end` closes this frame.
    try v.pushCtrl(.block, empty, ft.results);
    for (instrs, 0..) |instr, i| {
        v.pc = i;
        // Mirrored into the thread-local so the CALLER can locate the failure: `v` dies with this
        // frame, and the offset lookup needs `code`, which only the caller has.
        pc_hint = i;
        try v.step(instr);
    }
    if (v.ctrls.items.len != 0) return error.ControlUnderflow; // missing `end`
}

/// Type-check one function *for the purpose of* annotating each `drop`/`select`
/// with its operand slot width (2 for a v128, else 1) — the interpreter needs
/// this to pop the right number of `u64` slots (a v128 is two). Returns an
/// array indexed by instruction position (1 everywhere except v128 drop/select).
///
/// Only called for functions that actually use v128 (see `interp`), so the
/// common non-SIMD path never pays for it. Tolerant: on a validation error it
/// returns the widths captured **before** the error — an error can only be at or
/// after an unsupported/invalid instruction, which the interpreter traps on
/// before reaching any later drop/select, so those later widths are never used.
///
/// **`OutOfMemory` is the exception to that tolerance and must propagate.** It
/// can arise at *any* point in `validateFunction`, not just at a bad
/// instruction, so the "everything after the error is unreachable" argument does
/// not hold for it: the widths simply stay at their `1` default, a v128
/// `drop`/`select` then pops one slot instead of two, and the operand stack is
/// desynchronised for the rest of the function. The module returns a **silently
/// wrong answer** with no trap and no diagnostic — one transient allocation
/// failure inside `Instance.init`, which still reports success.
///
/// Reachable by any memory-capped embedder: a *budgeted* allocator (like the one
/// in `fuzz.zig`) refuses while over its limit and succeeds again after frees, so
/// a single failure here is transient rather than terminal. Sticky
/// `FailingAllocator` sweeps cannot see this, which is why it went unnoticed.
pub fn dropSelectWidths(a: std.mem.Allocator, module: *const Module, ft: Module.FuncType, code: Module.Code) std.mem.Allocator.Error![]const u8 {
    // The caller (interp) already decoded this body successfully, so re-decoding
    // here fails only on OOM; a (hypothetical) decode error → empty = all width 1.
    const instrs = opcode.decodeBody(a, code.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const widths = try a.alloc(u8, instrs.len);
    @memset(widths, 1);
    // `refs` is null: this is a LOWERING pass, not a verdict — the caller has
    // already validated (or will), and a C.refs rejection here would only
    // truncate the width table it is trying to fill in.
    validateFunction(a, module, ft, code, widths, null) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
    };
    return widths;
}

// --- The validation algorithm ---------------------------------------------

const StackType = union(enum) { val: V, unknown };

const FrameKind = enum { block, loop, if_, else_, try_table, try_legacy, catch_legacy };

const Frame = struct {
    kind: FrameKind,
    start: []const V,
    end: []const V,
    height: usize,
    is_unreachable: bool,
    /// Local-init state at this frame's entry; a structured control instruction
    /// restores it on `else`/`end` (inner sets don't escape the construct).
    init_snapshot: []bool,
};

const FuncValidator = struct {
    a: std.mem.Allocator,
    module: *const Module,
    /// Declared function references (C.refs). Null in lowering-only passes,
    /// where a C.refs verdict is not wanted.
    refs: ?*const std.DynamicBitSetUnmanaged,
    locals: []const V,
    results: []const V,
    /// Whether each local is currently known-initialized (params + defaultable
    /// locals start true; non-nullable-ref locals start false).
    local_init: []bool,
    vals: std.ArrayList(StackType) = .empty,
    ctrls: std.ArrayList(Frame) = .empty,
    /// Optional: per-instruction operand *slot width* (2 for a v128 `drop`/
    /// `select`, else 1), written as those ops are checked. Used by the interp to
    /// pop the right slot count (SIMD). Null when validating for correctness only.
    widths: ?[]u8 = null,
    /// Index of the instruction currently being checked (for `widths`).
    pc: usize = 0,
    /// Instruction count of the body being checked. Used as a sound upper bound
    /// on how many operands an instruction can legitimately consume (see
    /// `array_new_fixed`).
    body_len: usize = 0,

    /// Record the slot width of a `drop`/`select` operand at the current pc
    /// (2 for v128, else 1) when width-capture is on.
    fn recordWidth(self: *FuncValidator, st: StackType) void {
        if (self.widths) |w| w[self.pc] = switch (st) {
            .val => |t| if (t == .v128) 2 else 1,
            .unknown => 1, // polymorphic (unreachable code) — never executed
        };
    }

    fn pushValT(self: *FuncValidator, t: V) Error!void {
        try self.vals.append(self.a, .{ .val = t });
    }
    fn pushVal(self: *FuncValidator, st: StackType) Error!void {
        try self.vals.append(self.a, st);
    }
    fn pushVals(self: *FuncValidator, ts: []const V) Error!void {
        for (ts) |t| try self.pushValT(t);
    }

    fn popVal(self: *FuncValidator) Error!StackType {
        const top = self.ctrls.items[self.ctrls.items.len - 1];
        if (self.vals.items.len == top.height) {
            if (top.is_unreachable) return .unknown;
            return error.StackUnderflow;
        }
        return self.vals.pop().?;
    }
    fn popExpect(self: *FuncValidator, expect: V) Error!StackType {
        const actual = try self.popVal();
        switch (actual) {
            .unknown => {},
            .val => |t| if (!subtypeOf(self.module, t, expect)) {
                // The one place that knows BOTH types, which is what makes wasmtime's
                // "expected i32, found i64" possible at all — the error tag carries nothing.
                site.expected = expect;
                site.found = t;
                return error.TypeMismatch;
            },
        }
        return actual;
    }
    fn popVals(self: *FuncValidator, ts: []const V) Error!void {
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            _ = try self.popExpect(ts[i]);
        }
    }

    /// `push_opds(pop_opds(ts))` — check that `ts` is on the stack and put back
    /// **exactly what was there**, which on a polymorphic stack is `unknown` (⊥)
    /// rather than the declared type. `popVals` + `pushVals` is NOT the same
    /// operation: it substitutes concrete types for ⊥ and so makes a later probe
    /// of the same slots fail. Used by `br_table`, which probes every label in
    /// turn. Falls back to the declared types beyond a small fixed arity, where
    /// nothing polymorphic can be involved in practice.
    fn popPushVals(self: *FuncValidator, ts: []const V) Error!void {
        var buf: [8]StackType = undefined;
        if (ts.len > buf.len) {
            try self.popVals(ts);
            try self.pushVals(ts);
            return;
        }
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            buf[i] = try self.popExpect(ts[i]);
        }
        for (buf[0..ts.len]) |st| try self.pushVal(st);
    }
    /// Pop a value that must be a reference type (or polymorphic `unknown`).
    /// A linear memory must exist AND the instruction's memory index must be in
    /// range. The second half matters for multi-memory: checking only
    /// `memories.len == 0` accepted `(i32.load (memory 7))` in a one-memory
    /// module.
    fn requireMemory(self: *FuncValidator, index: u32) Error!void {
        if (index >= self.module.memories.len) return error.MissingMemory;
    }

    /// A function body naming a DATA index requires the data-count section
    /// (§5.5.13), whatever the instruction — the section exists so the code
    /// section can be validated before the data section is read. `memory.init`
    /// and `data.drop` inlined this pair of checks; `array.new_data` /
    /// `array.init_data` are data-index references too and need exactly the same
    /// rule, so it lives in one place now rather than in four copies.
    fn requireDataSegment(self: *FuncValidator, index: u32) Error!void {
        if (self.module.data_count == null) return error.DataCountRequired;
        if (index >= self.module.data.len) return error.UndefinedData;
    }

    /// The address/count value type of memory `index` — `i64` for a memory64
    /// memory, else `i32`. Callers `requireMemory` first, so the index is valid.
    fn memAddrTy(self: *FuncValidator, index: u32) V {
        return if (self.module.memories[index].limits.is64) .i64 else .i32;
    }

    /// The INDEX type of a table: `i64` for a 64-bit table (the table64 half of
    /// memory64), else `i32`. Every table index, length and count operand takes
    /// this type — they were all hard-coded `.i32`, which is why a 64-bit table
    /// could not be used even once it decoded.
    ///
    /// Callers bounds-check the index first (`tableElemType`), except where noted.
    fn tableAddrTy(self: *FuncValidator, index: u32) V {
        if (index >= self.module.tables.len) return .i32; // unreachable after the check
        return if (self.module.tables[index].limits.is64) .i64 else .i32;
    }

    /// A memarg offset is decoded as `u64` (memory64), but on a 32-bit memory it
    /// must fit in `u32`. Callers `requireMemory` first, so the index is valid.
    fn checkMemOffset(self: *FuncValidator, index: u32, offset: u64) Error!void {
        if (!self.module.memories[index].limits.is64 and offset > std.math.maxInt(u32))
            return error.InvalidMemArgOffset;
    }

    fn popRef(self: *FuncValidator) Error!StackType {
        const st = try self.popVal();
        switch (st) {
            .val => |v| if (!v.isRef()) return error.TypeMismatch,
            .unknown => {},
        }
        return st;
    }

    /// True if the innermost control frame is in unreachable (polymorphic) code.
    fn topUnreachable(self: *FuncValidator) bool {
        return self.ctrls.items.len != 0 and self.ctrls.items[self.ctrls.items.len - 1].is_unreachable;
    }

    fn pushCtrl(self: *FuncValidator, kind: FrameKind, start: []const V, end: []const V) Error!void {
        if (self.ctrls.items.len >= max_ctrl_depth) return error.NestingTooDeep;
        try self.ctrls.append(self.a, .{
            .kind = kind,
            .start = start,
            .end = end,
            .height = self.vals.items.len,
            .is_unreachable = false,
            .init_snapshot = try self.a.dupe(bool, self.local_init),
        });
        try self.pushVals(start);
    }
    fn popCtrl(self: *FuncValidator) Error!Frame {
        if (self.ctrls.items.len == 0) return error.ControlUnderflow;
        const frame = self.ctrls.items[self.ctrls.items.len - 1];
        try self.popVals(frame.end);
        if (self.vals.items.len != frame.height) return error.StackHeightMismatch;
        _ = self.ctrls.pop();
        return frame;
    }
    fn setUnreachable(self: *FuncValidator) void {
        const top = &self.ctrls.items[self.ctrls.items.len - 1];
        self.vals.shrinkRetainingCapacity(top.height);
        top.is_unreachable = true;
    }

    /// Label types of the frame `n` levels from the top (`br`/`br_if`/`br_table`).
    fn labelTypesAt(self: *FuncValidator, n: u32) Error![]const V {
        if (n >= self.ctrls.items.len) return error.UnknownLabel;
        const frame = self.ctrls.items[self.ctrls.items.len - 1 - n];
        return if (frame.kind == .loop) frame.start else frame.end;
    }

    fn localAt(self: *FuncValidator, i: u32) Error!V {
        if (i >= self.locals.len) return error.UndefinedLocal;
        return self.locals[i];
    }
    fn globalAt(self: *FuncValidator, i: u32) Error!Module.GlobalType {
        if (i >= self.module.globals.len) return error.UndefinedGlobal;
        return self.module.globals[i];
    }
    fn tableElemType(self: *FuncValidator, i: u32) Error!V {
        if (i >= self.module.tables.len) return error.UndefinedTable;
        return self.module.tables[i].element;
    }

    const Sig = struct { pop: []const V, push: []const V };

    fn blockSig(self: *FuncValidator, bt: opcode.BlockType) Error!Sig {
        return switch (bt) {
            .empty => .{ .pop = empty, .push = empty },
            .value => |t| blk: {
                const r = try self.a.alloc(V, 1);
                r[0] = t;
                break :blk .{ .pop = empty, .push = r };
            },
            .type_index => |i| blk: {
                const ft = self.module.funcSig(i) orelse return error.UndefinedType;
                break :blk .{ .pop = ft.params, .push = ft.results };
            },
            // A single `(ref null? ht)` result. `refTypeValType` resolves a
            // concrete index to its family head and — the point of this arm —
            // fails `UndefinedType` when the index names no type at all, which is
            // the "unknown type" `ref.wast` asks for.
            .ref => |rt| blk: {
                const r = try self.a.alloc(V, 1);
                r[0] = try refTypeValType(self.module, rt);
                break :blk .{ .pop = empty, .push = r };
            },
        };
    }

    /// Every `want[i]` must be a subtype of `got[i]` (same length). Used to check
    /// that a catch handler's pushed values fit its target label.
    fn matchTypes(self: *FuncValidator, want: []const V, got: []const V) Error!void {
        if (want.len != got.len) return error.TypeMismatch;
        for (want, got) |w, g| if (!subtypeOf(self.module, w, g)) return error.TypeMismatch;
    }

    /// A `try_table` catch clause branches to `lt` (its target label's types)
    /// carrying the tag's params (`catch`/`catch_ref`) — plus an `exnref` for the
    /// `_ref` variants, and nothing for `catch_all`. Check those match `lt`.
    fn checkCatch(self: *FuncValidator, c: opcode.Catch, lt: []const V) Error!void {
        switch (c.kind) {
            .catch_ => {
                const ft = self.module.tagType(c.tag) orelse return error.UndefinedTag;
                try self.matchTypes(ft.params, lt);
            },
            // ⚠️ The exception reference a `_ref` clause materializes is `(ref exn)`
            // — NON-NULL. Checking it as the nullable `exnref` made the handler's
            // pushed type weaker than it really is, so a label declaring
            // `(ref exn)` was rejected: nullable does not satisfy a non-null
            // expectation. `try_table.wast`'s `catch_ref1`/`catch_all_ref1` are
            // exactly that module. The nullable-label case still passes, because
            // `(ref exn) <: (ref null exn)` — the fix only widens what is accepted,
            // in the direction the spec already required.
            .catch_ref => {
                const ft = self.module.tagType(c.tag) orelse return error.UndefinedTag;
                if (lt.len != ft.params.len + 1) return error.TypeMismatch;
                try self.matchTypes(ft.params, lt[0..ft.params.len]);
                if (!subtypeOf(self.module, .exnref_nn, lt[lt.len - 1])) return error.TypeMismatch;
            },
            .catch_all => if (lt.len != 0) return error.TypeMismatch,
            .catch_all_ref => if (lt.len != 1 or !subtypeOf(self.module, .exnref_nn, lt[0])) return error.TypeMismatch,
        }
    }

    fn step(self: *FuncValidator, instr: opcode.Instr) Error!void {
        if (self.ctrls.items.len == 0) return error.ControlUnderflow; // code after final `end`
        switch (instr.op) {
            .@"unreachable" => self.setUnreachable(),
            .nop => {},

            .block => {
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.block, s.pop, s.push);
            },
            .loop => {
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.loop, s.pop, s.push);
            },
            .@"if" => {
                _ = try self.popExpect(.i32);
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.if_, s.pop, s.push);
            },

            // Exception handling (exnref proposal, Phase 6).
            .try_table => {
                const tt = instr.imm.try_table;
                const s = try self.blockSig(tt.block_type);
                // ⚠️ **Catch labels resolve in the ENCLOSING context, NOT with the
                // try_table's own frame pushed** (EH proposal §3.4: the catches are
                // checked in `C`, only the body in `C, labels [t2*]`). This ran
                // AFTER `pushCtrl`, so every catch label was off by one frame —
                // and it failed in both directions at once:
                //
                //   (func (result exnref) (try_table (catch 0 0)) (unreachable))
                //     — label 0 is the FUNCTION's block `[exnref]`, so a plain
                //       `catch` delivering `[]` is a type mismatch. We resolved it
                //       to the try_table's own empty block and ACCEPTED it.
                //   (func (result exnref) (try_table (catch_ref $e 0) …))
                //     — the same label is `[exnref]`, which `catch_ref` fits
                //       exactly. We resolved it to `[]` and REJECTED a valid module.
                //
                // One off-by-one frame, an accept-invalid and a false reject in the
                // same file. `wat.zig`'s `emitCatchClauses` had the mirror error, so
                // a `$name` catch target resolved to the same wrong depth and the
                // two halves agreed — the producer/consumer blind spot again.
                for (tt.catches) |c| {
                    const lt = try self.labelTypesAt(c.label);
                    try self.checkCatch(c, lt);
                }
                try self.popVals(s.pop);
                try self.pushCtrl(.try_table, s.pop, s.push);
            },
            .throw => {
                const ft = self.module.tagType(instr.imm.tag) orelse return error.UndefinedTag;
                if (ft.results.len != 0) return error.InvalidTag; // tags never produce results
                try self.popVals(ft.params); // consume the exception's operands
                self.setUnreachable(); // control transfers; the rest is dead
            },

            // Legacy exception handling (older-LLVM encoding, Phase 6.3). The
            // interpreter has always executed these, but the validator had no
            // arms for them — so a legacy-EH module ran on the raw path yet was
            // rejected by `validate` (and thus by the `.wast` runner and the
            // summarize path). A `try` opens a block-typed frame; each `catch`/
            // `catch_all` closes the preceding section (which must produce the
            // try's results) and opens a handler that starts with the tag's
            // params; `end`/`delegate` close the construct.
            .try_ => {
                const s = try self.blockSig(instr.imm.block_type);
                try self.popVals(s.pop);
                try self.pushCtrl(.try_legacy, s.pop, s.push);
            },
            .catch_, .catch_all => {
                const frame = try self.popCtrl();
                if (frame.kind != .try_legacy and frame.kind != .catch_legacy) return error.MismatchedCatch;
                // The handler starts from the try's ENTRY init state — locals set
                // in the body (or a prior handler) are not guaranteed on the path
                // that reached this catch via a thrown exception (§ same rule as
                // `else`).
                @memcpy(self.local_init, frame.init_snapshot);
                const start: []const V = if (instr.op == .catch_) blk: {
                    const ft = self.module.tagType(instr.imm.tag) orelse return error.UndefinedTag;
                    if (ft.results.len != 0) return error.InvalidTag;
                    break :blk ft.params; // the caught exception's operands
                } else empty; // catch_all binds nothing
                try self.pushCtrl(.catch_legacy, start, frame.end);
            },
            .delegate => {
                // `delegate l` re-raises an exception "at label l", which can SKIP
                // the handlers of trys between this one and the target. The
                // interpreter records the label but `throwException` never routes
                // through it, and there is no reference implementation left to
                // validate the (subtle, historically-inconsistent) label
                // arithmetic against — wasmtime and V8 dropped the legacy EH
                // encoding for `try_table`. Rather than accept a construct we
                // cannot correctly execute (the "validates yet mis-runs" trap the
                // assembler already refuses by rejecting `delegate`), reject it
                // here too, so text and binary paths agree. `try`/`catch`/
                // `catch_all`/`rethrow` remain fully supported.
                return error.UnsupportedOpcode;
            },
            .rethrow => {
                // Re-raise the exception caught `l` levels out. `l` must resolve
                // AND must name a `catch`/`catch_all` block — there is no caught
                // exception at any other kind of label, so `(func (rethrow 0))`
                // and `(func (block (rethrow 0)))` are invalid, not merely odd.
                //
                // We checked only that the label resolved, so both were ACCEPTED
                // (`rethrow.wast`, "invalid rethrow label"). At run time
                // `handler_exn` was then whatever the enclosing frame happened to
                // leave there — a wrong exception re-raised, or a trap, decided by
                // unrelated code. Same accept-invalid class as T1, in a feature we
                // do implement.
                if (instr.imm.label >= self.ctrls.items.len) return error.UnknownLabel;
                const target = self.ctrls.items[self.ctrls.items.len - 1 - instr.imm.label];
                if (target.kind != .catch_legacy) return error.InvalidRethrowLabel;
                self.setUnreachable();
            },
            .throw_ref => {
                _ = try self.popExpect(.exnref);
                self.setUnreachable();
            },
            .@"else" => {
                const frame = try self.popCtrl();
                if (frame.kind != .if_) return error.MismatchedElse;
                // The else branch starts from the if's entry init state (sets in
                // the then branch don't carry over).
                @memcpy(self.local_init, frame.init_snapshot);
                try self.pushCtrl(.else_, frame.start, frame.end);
            },
            .end => {
                const frame = try self.popCtrl();
                // An `if` closed without an `else` has an implicit identity else
                // branch, which requires the param and result types to match.
                if (frame.kind == .if_ and !std.mem.eql(V, frame.start, frame.end)) return error.TypeMismatch;
                // Restore the entry init state — inner sets don't escape (§3.3.5).
                @memcpy(self.local_init, frame.init_snapshot);
                try self.pushVals(frame.end);
            },

            .br => {
                const lt = try self.labelTypesAt(instr.imm.label);
                try self.popVals(lt);
                self.setUnreachable();
            },
            .br_if => {
                _ = try self.popExpect(.i32);
                const lt = try self.labelTypesAt(instr.imm.label);
                try self.popVals(lt);
                try self.pushVals(lt);
            },
            .br_table => {
                _ = try self.popExpect(.i32);
                const default_lt = try self.labelTypesAt(instr.imm.br_table.default);
                for (instr.imm.br_table.labels) |l| {
                    const lt = try self.labelTypesAt(l);
                    if (lt.len != default_lt.len) return error.TypeMismatch;
                    // ⚠️ **A "#2f" pairwise subtype check between each label and
                    // the default used to live here, and the spec has no such
                    // rule.** §3.3.5.9 asks for a single `[t*]` that is a subtype
                    // of every label's type; after `unreachable` the operand stack
                    // supplies ⊥, which is a subtype of anything, so labels that
                    // are pairwise incompatible are still jointly satisfiable.
                    // `br_table.wast` names the case `meet-bottom`:
                    //
                    //     (block (result f64) (block (result f32)
                    //       (unreachable) (br_table 0 1 1 (i32.const 1))))
                    //
                    // f32 and f64 have no common supertype and the module is
                    // VALID. The check's own comment claimed it "never rejects a
                    // valid subtyped `br_table`"; it rejected this one and took the
                    // other **161 assertions in the file** into `NoTarget`.
                    //
                    // It was redundant in the other direction too: in REACHABLE
                    // code the pop/push below already catches a genuine mismatch,
                    // because the first label leaves a concrete type the next
                    // label's pop must satisfy. The algorithm below is the
                    // Appendix's, unmodified — arity equality plus
                    // `push_opds(pop_opds(label_types(l)))` — and arity is the only
                    // cross-label rule there is: one `[t*]` cannot have two lengths.
                    // ⚠️ Push back WHAT WAS POPPED, not the label's declared types.
                    // `popVals(lt); pushVals(lt);` looks like a non-destructive
                    // probe and is not: on a polymorphic stack `popVals` consumes
                    // `unknown` (⊥) entries while `pushVals` puts CONCRETE ones
                    // back, so checking label 0 of `meet-bottom` left a real `f32`
                    // where ⊥ had been, and checking label 1 then failed
                    // "expected f64, found f32". §Appendix's algorithm is
                    // `push_opds(pop_opds(…))` — the popped entries, ⊥ and all.
                    try self.popPushVals(lt);
                }
                try self.popVals(default_lt);
                self.setUnreachable();
            },
            .@"return" => {
                try self.popVals(self.results);
                self.setUnreachable();
            },

            .call => {
                const ft = self.module.funcType(instr.imm.func) orelse return error.UndefinedFunc;
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },
            // Tail calls (§3.3.8). The callee REPLACES this frame, so its results
            // become this function's results — they must be a SUBTYPE sequence of
            // them (see `resultsSubtype`; this was an equality check, which is
            // reject-valid for every widening return), and nothing after the
            // instruction is reachable. `return_call_ref` already had this shape;
            // these two are its plain and indirect siblings.
            .return_call => {
                const ft = self.module.funcType(instr.imm.func) orelse return error.UndefinedFunc;
                try self.popVals(ft.params);
                if (!resultsSubtype(self.module, ft.results, self.results)) return error.TypeMismatch;
                self.setUnreachable();
            },
            .return_call_indirect => {
                const ci = instr.imm.call_indirect;
                if (ci.table >= self.module.tables.len) return error.UndefinedTable;
                if (!subtypeOf(self.module, self.module.tables[ci.table].element, .funcref)) return error.TypeMismatch;
                const ft = self.module.funcSig(ci.type_index) orelse return error.UndefinedType;
                _ = try self.popExpect(self.tableAddrTy(ci.table)); // the callee index
                try self.popVals(ft.params);
                if (!resultsSubtype(self.module, ft.results, self.results)) return error.TypeMismatch;
                self.setUnreachable();
            },
            .call_indirect => {
                const ci = instr.imm.call_indirect;
                if (ci.table >= self.module.tables.len) return error.UndefinedTable;
                // Spec §3.3.8: the table.s reftype must MATCH `(ref null func)`, not
                // equal `funcref` exactly — a `(table 1 (ref null $ft))` or
                // `(table 1 (ref func))` is valid and was rejected.
                if (!subtypeOf(self.module, self.module.tables[ci.table].element, .funcref)) return error.TypeMismatch;
                const ft = self.module.funcSig(ci.type_index) orelse return error.UndefinedType;
                _ = try self.popExpect(self.tableAddrTy(ci.table)); // the callee index
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },

            .drop => {
                const t = try self.popVal();
                self.recordWidth(t);
            },
            .select => {
                // Untyped select: operands must be equal and a *numeric/vector*
                // type — reference-typed operands require the typed form.
                _ = try self.popExpect(.i32);
                const t1 = try self.popVal();
                const t2 = try self.popVal();
                if (isRefStack(t1) or isRefStack(t2)) return error.TypeMismatch;
                const rt: StackType = switch (t1) {
                    .unknown => t2,
                    .val => |a| switch (t2) {
                        .unknown => t1,
                        .val => |b| if (a == b) t1 else return error.TypeMismatch,
                    },
                };
                self.recordWidth(rt);
                try self.pushVal(rt);
            },
            .select_t => {
                // Typed select: the annotation must be exactly one type; both
                // operands must match it.
                const tys = instr.imm.select_types;
                if (tys.len != 1) return error.TypeMismatch; // invalid result arity
                _ = try self.popExpect(.i32);
                _ = try self.popExpect(tys[0]);
                _ = try self.popExpect(tys[0]);
                if (self.widths) |w| w[self.pc] = if (tys[0] == .v128) 2 else 1;
                try self.pushValT(tys[0]);
            },
            .simd => {
                // A memory-touching `0xFD` op needs a memory to exist, and its
                // memarg's memory index must be in range (multi-memory). Neither
                // was checked, so every SIMD load/store validated in a module
                // with no memory at all — accept-invalid. Contained at run time
                // by `Frame.memBytes` (`NoMemory`), but `validate` is the gate an
                // embedder calling `wasm_module_validate` relies on.
                const sub = instr.imm.simd.sub;
                const s = simdSig(sub);
                if (opcode.simdIsMemoryOp(sub)) {
                    const mi = instr.imm.simd.mem.memory;
                    try self.requireMemory(mi);
                    // …and the memarg alignment rule (§6.5.8, `align <= N/8`), which
                    // the scalar path enforces but this arm skipped entirely, so
                    // `v128.store align=64` validated.
                    if (instr.imm.simd.mem.alignment > opcode.simdNaturalAlignLog2(sub))
                        return error.InvalidAlignment;
                    try self.checkMemOffset(mi, instr.imm.simd.mem.offset);
                    // memory64: the address operand is the memory's index type, not
                    // the `i32` baked into `simdSig`. `s.pop[0]` is always the
                    // address; pop the trailing v128 value(s) top-first, then it.
                    const at = self.memAddrTy(mi);
                    var k = s.pop.len;
                    while (k > 1) : (k -= 1) _ = try self.popExpect(s.pop[k - 1]);
                    _ = try self.popExpect(at);
                    try self.pushVals(s.push);
                } else {
                    try self.popVals(s.pop);
                    try self.pushVals(s.push);
                }
            },

            .atomic => {
                const sub = instr.imm.atomic.sub;
                if (sub == 0x03) { // atomic.fence: no memory, no operands
                    return;
                }
                // Every other atomic op touches memory and MUST be naturally
                // aligned (§ threads: the alignment is fixed, not a max).
                try self.requireMemory(instr.imm.atomic.mem.memory);
                if (instr.imm.atomic.mem.alignment != opcode.atomicNaturalAlignLog2(sub))
                    return error.InvalidAlignment;
                try self.checkMemOffset(instr.imm.atomic.mem.memory, instr.imm.atomic.mem.offset);
                // memory64: the ADDRESS operand (the deepest one) is i64.
                const adt = self.memAddrTy(instr.imm.atomic.mem.memory);
                switch (sub) {
                    0x00 => { // notify: [addr count] -> [i32]
                        _ = try self.popExpect(.i32);
                        _ = try self.popExpect(adt);
                        try self.pushValT(.i32);
                    },
                    0x01 => { // wait32: [addr i32 i64] -> [i32]
                        _ = try self.popExpect(.i64);
                        _ = try self.popExpect(.i32);
                        _ = try self.popExpect(adt);
                        try self.pushValT(.i32);
                    },
                    0x02 => { // wait64: [addr i64 i64] -> [i32]
                        _ = try self.popExpect(.i64);
                        _ = try self.popExpect(.i64);
                        _ = try self.popExpect(adt);
                        try self.pushValT(.i32);
                    },
                    0x10...0x16 => { // atomic load: [addr] -> [T]
                        _ = try self.popExpect(adt);
                        try self.pushValT(atomicValType(sub));
                    },
                    0x17...0x1d => { // atomic store: [addr T] -> []
                        _ = try self.popExpect(atomicValType(sub));
                        _ = try self.popExpect(adt);
                    },
                    0x1e...0x47 => { // rmw: [addr T] -> [T]
                        const t = atomicValType(sub);
                        _ = try self.popExpect(t);
                        _ = try self.popExpect(adt);
                        try self.pushValT(t);
                    },
                    0x48...0x4e => { // cmpxchg: [addr expected replacement] -> [T]
                        const t = atomicValType(sub);
                        _ = try self.popExpect(t);
                        _ = try self.popExpect(t);
                        _ = try self.popExpect(adt);
                        try self.pushValT(t);
                    },
                    else => return error.UnsupportedOpcode,
                }
            },

            .table_get => {
                const et = try self.tableElemType(instr.imm.table);
                _ = try self.popExpect(self.tableAddrTy(instr.imm.table));
                try self.pushValT(et);
            },
            .table_set => {
                const et = try self.tableElemType(instr.imm.table);
                _ = try self.popExpect(et);
                _ = try self.popExpect(self.tableAddrTy(instr.imm.table));
            },
            .table_size => {
                _ = try self.tableElemType(instr.imm.table); // bounds-check the index
                try self.pushValT(self.tableAddrTy(instr.imm.table));
            },
            .table_grow => {
                const et = try self.tableElemType(instr.imm.table);
                const at = self.tableAddrTy(instr.imm.table);
                _ = try self.popExpect(at); // delta
                _ = try self.popExpect(et); // init value
                try self.pushValT(at); // previous size
            },
            .table_fill => {
                const et = try self.tableElemType(instr.imm.table);
                const at = self.tableAddrTy(instr.imm.table);
                _ = try self.popExpect(at); // n
                _ = try self.popExpect(et); // value
                _ = try self.popExpect(at); // dst
            },
            .table_init => {
                const tet = try self.tableElemType(instr.imm.table_init.table);
                if (instr.imm.table_init.elem >= self.module.elements.len) return error.UndefinedElem;
                // Spec: the segment.s reftype must be a SUBTYPE of the table.s, not
                // equal to it — an `(elem (ref func) …)` into a `funcref` table is
                // valid and was rejected.
                if (!subtypeOf(self.module, self.module.elements[instr.imm.table_init.elem].elem_type, tet)) return error.TypeMismatch;
                // `src` and `n` index the ELEMENT SEGMENT, which is always 32-bit;
                // only `dst` takes the destination table's index type.
                _ = try self.popExpect(.i32); // n
                _ = try self.popExpect(.i32); // src
                _ = try self.popExpect(self.tableAddrTy(instr.imm.table_init.table)); // dst
            },
            .elem_drop => {
                if (instr.imm.elem >= self.module.elements.len) return error.UndefinedElem;
            },

            // Bulk memory. All three take `[dst, src|byte, n]` as i32 and need a
            // linear memory; `memory.init`/`data.drop` also need a valid data index.
            .memory_copy, .memory_fill => {
                // Bulk ops name a memory INDEX; testing only `len == 0` accepted
                // `memory.fill (memory 7)` in a one-memory module. Sibling of the
                // load/store hole `requireMemory` was added to close.
                // memory64: address/count operands take the memory's index type.
                switch (instr.op) {
                    .memory_fill => {
                        try self.requireMemory(instr.imm.mem_index);
                        const at = self.memAddrTy(instr.imm.mem_index);
                        _ = try self.popExpect(at); // n
                        _ = try self.popExpect(.i32); // fill byte (always i32)
                        _ = try self.popExpect(at); // dst
                    },
                    else => { // memory.copy
                        try self.requireMemory(instr.imm.mem_copy.dst);
                        try self.requireMemory(instr.imm.mem_copy.src);
                        const dt = self.memAddrTy(instr.imm.mem_copy.dst);
                        const st = self.memAddrTy(instr.imm.mem_copy.src);
                        // n is the smaller index type (i32 unless both are i64).
                        const nt: V = if (dt == .i64 and st == .i64) .i64 else .i32;
                        _ = try self.popExpect(nt); // n
                        _ = try self.popExpect(st); // src
                        _ = try self.popExpect(dt); // dst
                    },
                }
            },
            .memory_init => {
                // WRONG UNION FIELD: `memory.init` decodes to `.mem_init{data, mem}`,
                // not `.data` — so this was `access of union field 'data' while
                // field 'mem_init' is active`, i.e. a **panic while validating a
                // VALID module** (LLVM emits `memory.init` for any passive data
                // segment). In ReleaseFast the members alias at offset 0, so it
                // silently read the right number — UB that happens to work, and
                // differs by build mode. `data_drop` below is correct; its
                // immediate really is `.data`.
                try self.requireMemory(instr.imm.mem_init.mem);
                try self.requireDataSegment(instr.imm.mem_init.data);
                _ = try self.popExpect(.i32); // n (count into the data segment — i32)
                _ = try self.popExpect(.i32); // src (offset into the segment — i32)
                _ = try self.popExpect(self.memAddrTy(instr.imm.mem_init.mem)); // dst address (memory64: i64)
            },
            .data_drop => try self.requireDataSegment(instr.imm.data),
            .table_copy => {
                const dt = try self.tableElemType(instr.imm.table_copy.dst);
                const st = try self.tableElemType(instr.imm.table_copy.src);
                // Same rule as table.init: src <: dst, not equality.
                if (!subtypeOf(self.module, st, dt)) return error.TypeMismatch;
                // Each table contributes its own index type, and `n` takes the
                // SMALLER of the two — same rule as `memory.copy`.
                const dat = self.tableAddrTy(instr.imm.table_copy.dst);
                const sat = self.tableAddrTy(instr.imm.table_copy.src);
                const nt: V = if (dat == .i64 and sat == .i64) .i64 else .i32;
                _ = try self.popExpect(nt); // n
                _ = try self.popExpect(sat); // src
                _ = try self.popExpect(dat); // dst
            },

            .ref_null => try self.pushValT(try refTypeValType(self.module, .{ .nullable = true, .heap = instr.imm.ref_type })),
            .ref_is_null => {
                switch (try self.popVal()) { // requires a reference type (or polymorphic)
                    .val => |v| if (!v.isRef()) return error.TypeMismatch,
                    .unknown => {},
                }
                try self.pushValT(.i32);
            },
            .ref_func => {
                if (self.module.funcType(instr.imm.func) == null) return error.UndefinedFunc;
                // C.refs (§3.4.10): a body may only reference a function some
                // module-level construct declared — an export, the start, a global
                // init, or an element segment (`(elem declare func $f)` exists
                // precisely to declare an otherwise-unmentioned function).
                if (self.refs) |set| if (!set.isSet(instr.imm.func)) return error.UndeclaredFuncRef;
                // A function reference is non-null and, for a defined function,
                // carries its concrete type (`(ref $ftype)`); imported funcs fall
                // back to the abstract funcref head (no type index kept).
                if (self.module.funcTypeIndex(instr.imm.func)) |ti|
                    try self.pushValT(V.concreteRef(false, .func, ti))
                else
                    try self.pushValT(.funcref_nn);
            },

            // Typed function references (function-references proposal). A typed
            // func ref collapses to `funcref` in our model (see the decoder P1).
            .call_ref => {
                const ft = self.module.funcSig(instr.imm.func) orelse return error.UndefinedType;
                // The immediate names the signature, so the operand must be a ref to
                // THAT type — `popExpect(.funcref)` accepted any funcref, so
                // `call_ref $a` on a `(ref $b)` delivered an i64 result as i32.
                _ = try self.popExpect(V.concreteRef(true, .func, instr.imm.func));
                try self.popVals(ft.params);
                try self.pushVals(ft.results);
            },
            .return_call_ref => {
                const ft = self.module.funcSig(instr.imm.func) orelse return error.UndefinedType;
                _ = try self.popExpect(V.concreteRef(true, .func, instr.imm.func));
                try self.popVals(ft.params);
                if (!resultsSubtype(self.module, ft.results, self.results)) return error.TypeMismatch;
                self.setUnreachable();
            },
            // GC: i31 references (full GC, P3). `ref.i31` boxes an i32 into a
            // non-null i31 ref; `i31.get_s`/`_u` project it back (traps on null).
            .ref_i31 => {
                _ = try self.popExpect(.i32);
                try self.pushValT(.i31ref_nn);
            },
            .i31_get_s, .i31_get_u => {
                _ = try self.popExpect(.i31ref); // (ref null i31) and its subtypes
                try self.pushValT(.i32);
            },

            // GC: eq references compare by identity.
            .ref_eq => {
                _ = try self.popExpect(.eqref);
                _ = try self.popExpect(.eqref);
                try self.pushValT(.i32);
            },

            // GC: struct objects (full GC, P3). Concrete `(ref $t)` operands
            // collapse to `structref` in our model; the exact type index rides in
            // the immediate (fields/mutability come from it).
            .struct_new => {
                const fields = self.module.structFields(instr.imm.gc_type) orelse return error.UndefinedType;
                var i = fields.len;
                while (i > 0) { // operands are pushed field 0 first → pop in reverse
                    i -= 1;
                    _ = try self.popExpect(fields[i].storage.unpacked());
                }
                try self.pushValT(V.concreteRef(false, .@"struct", instr.imm.gc_type));
            },
            .struct_new_default => {
                const fields = self.module.structFields(instr.imm.gc_type) orelse return error.UndefinedType;
                for (fields) |f| if (f.storage.unpacked().isNonNullRef()) return error.TypeMismatch; // not defaultable
                try self.pushValT(V.concreteRef(false, .@"struct", instr.imm.gc_type));
            },
            .struct_get, .struct_get_s, .struct_get_u => {
                const gf = instr.imm.gc_field;
                const fields = self.module.structFields(gf.type_index) orelse return error.UndefinedType;
                if (gf.field >= fields.len) return error.UndefinedField;
                const field = fields[gf.field];
                try requirePacking(instr.op == .struct_get, field.storage);
                // Pop the CONCRETE type, not the family head: popping `.structref`
                // let ANY struct ref satisfy ANY `struct.*`, so `struct.get $b 0`
                // on a `(ref $a)` reinterpreted an i64 field as a funcref and
                // `call_ref` then CALLED it. `subtypeOf` already walks the
                // declared supertype chain for concrete/concrete.
                _ = try self.popExpect(V.concreteRef(true, .@"struct", gf.type_index));
                try self.pushValT(field.storage.unpacked());
            },
            .struct_set => {
                const gf = instr.imm.gc_field;
                const fields = self.module.structFields(gf.type_index) orelse return error.UndefinedType;
                if (gf.field >= fields.len) return error.UndefinedField;
                if (!fields[gf.field].mutable) return error.ImmutableField;
                _ = try self.popExpect(fields[gf.field].storage.unpacked());
                _ = try self.popExpect(V.concreteRef(true, .@"struct", gf.type_index));
            },

            // GC: array objects. `t'` is the (unpacked) element type.
            .array_new => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                _ = try self.popExpect(.i32); // length
                _ = try self.popExpect(f.storage.unpacked()); // init value
                try self.pushValT(V.concreteRef(false, .array, instr.imm.gc_type));
            },
            .array_new_default => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                if (f.storage.unpacked().isNonNullRef()) return error.TypeMismatch; // not defaultable
                _ = try self.popExpect(.i32); // length
                try self.pushValT(V.concreteRef(false, .array, instr.imm.gc_type));
            },
            .array_new_fixed => {
                const tn = instr.imm.gc_type_n;
                const f = self.module.arrayField(tn.type_index) orelse return error.UndefinedType;
                // `n` is an unvalidated u32. In *unreachable* code `popExpect`
                // returns `.unknown` instead of underflowing, so the loop would
                // spin up to 2^32 times on a tiny module. Every operand must have
                // been produced by at least one instruction, so a valid `n` can
                // never exceed the body's instruction count — bounding by it
                // kills the spin without being able to reject a valid module.
                if (tn.n > self.body_len) return error.StackUnderflow;
                var k: u32 = 0;
                while (k < tn.n) : (k += 1) _ = try self.popExpect(f.storage.unpacked());
                try self.pushValT(V.concreteRef(false, .array, tn.type_index));
            },
            .array_get, .array_get_s, .array_get_u => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                try requirePacking(instr.op == .array_get, f.storage);
                _ = try self.popExpect(.i32); // index
                // Concrete, not the family head — see `struct.get`. Popping
                // `.arrayref` let any array ref satisfy any `array.*`, so
                // `array.get $y` on a `(ref $x)` forged a funcref from an i64.
                _ = try self.popExpect(V.concreteRef(true, .array, instr.imm.gc_type));
                try self.pushValT(f.storage.unpacked());
            },
            .array_set => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                if (!f.mutable) return error.ImmutableField;
                _ = try self.popExpect(f.storage.unpacked()); // value
                _ = try self.popExpect(.i32); // index
                _ = try self.popExpect(V.concreteRef(true, .array, instr.imm.gc_type));
            },
            .array_len => {
                _ = try self.popExpect(.arrayref); // (ref null array)
                try self.pushValT(.i32);
            },

            // GC: the array BULK ops. All six were missing until R3 (2026-08-13).
            //
            // `array.new_data $t $d : [i32 i32] -> [(ref $t)]` — the operands are a
            // byte OFFSET into the data segment and an element COUNT. §3.3.7: the
            // element type must be numeric/vector/packed; a REFERENCE element has
            // no byte encoding, so a data segment cannot initialise one.
            .array_new_data => {
                const gd = instr.imm.gc_data;
                const f = self.module.arrayField(gd.type_index) orelse return error.UndefinedType;
                if (f.storage.unpacked().isRef()) return error.TypeMismatch;
                try self.requireDataSegment(gd.data);
                _ = try self.popExpect(.i32); // size (in elements)
                _ = try self.popExpect(.i32); // offset (in bytes, into the segment)
                try self.pushValT(V.concreteRef(false, .array, gd.type_index));
            },
            // `array.new_elem $t $e : [i32 i32] -> [(ref $t)]` — the mirror over an
            // ELEMENT segment, so the element type must be a reference the segment
            // can produce: `elem_type <: t'`, the same subtyping rule `table.init`
            // uses (R2's C3 — family equality here would reject a valid module).
            .array_new_elem => {
                const ge = instr.imm.gc_elem;
                const f = self.module.arrayField(ge.type_index) orelse return error.UndefinedType;
                if (ge.elem >= self.module.elements.len) return error.UndefinedElem;
                if (!subtypeOf(self.module, self.module.elements[ge.elem].elem_type, f.storage.unpacked())) return error.TypeMismatch;
                _ = try self.popExpect(.i32); // size (in elements)
                _ = try self.popExpect(.i32); // offset (in elements, into the segment)
                try self.pushValT(V.concreteRef(false, .array, ge.type_index));
            },
            // `array.fill $t : [(ref null $t) i32 t' i32] -> []` (array, index,
            // value, count). Writes, so the element must be mutable.
            .array_fill => {
                const f = self.module.arrayField(instr.imm.gc_type) orelse return error.UndefinedType;
                if (!f.mutable) return error.ImmutableField;
                _ = try self.popExpect(.i32); // count
                _ = try self.popExpect(f.storage.unpacked()); // value
                _ = try self.popExpect(.i32); // index
                _ = try self.popExpect(V.concreteRef(true, .array, instr.imm.gc_type));
            },
            // `array.copy $t1 $t2 : [(ref null $t1) i32 (ref null $t2) i32 i32] -> []`
            // (dst, dst_off, src, src_off, len). The destination must be mutable and
            // the source element type a subtype of the destination's — the packed
            // widths therefore agree, which is what lets the interpreter copy the
            // stored `Value`s directly.
            .array_copy => {
                const ac = instr.imm.gc_array_copy;
                const df = self.module.arrayField(ac.dst) orelse return error.UndefinedType;
                const sf = self.module.arrayField(ac.src) orelse return error.UndefinedType;
                if (!df.mutable) return error.ImmutableField;
                // Packed storage is not a value type, so `unpacked()` alone would
                // call `(array i8)` and `(array i32)` compatible — both project i32.
                // Compare the STORAGE forms first, then the value types.
                if (df.storage.isPacked() or sf.storage.isPacked()) {
                    if (!std.meta.eql(df.storage, sf.storage)) return error.TypeMismatch;
                } else if (!subtypeOf(self.module, sf.storage.unpacked(), df.storage.unpacked())) {
                    return error.TypeMismatch;
                }
                _ = try self.popExpect(.i32); // len
                _ = try self.popExpect(.i32); // src offset
                _ = try self.popExpect(V.concreteRef(true, .array, ac.src));
                _ = try self.popExpect(.i32); // dst offset
                _ = try self.popExpect(V.concreteRef(true, .array, ac.dst));
            },
            // `array.init_data $t $d : [(ref null $t) i32 i32 i32] -> []`
            // (array, dst_off, src_byte_off, len). Same element-type restriction as
            // `array.new_data`, plus mutability because it writes in place.
            .array_init_data => {
                const gd = instr.imm.gc_data;
                const f = self.module.arrayField(gd.type_index) orelse return error.UndefinedType;
                if (!f.mutable) return error.ImmutableField;
                if (f.storage.unpacked().isRef()) return error.TypeMismatch;
                try self.requireDataSegment(gd.data);
                _ = try self.popExpect(.i32); // len
                _ = try self.popExpect(.i32); // src offset (bytes)
                _ = try self.popExpect(.i32); // dst offset (elements)
                _ = try self.popExpect(V.concreteRef(true, .array, gd.type_index));
            },
            // `array.init_elem $t $e : [(ref null $t) i32 i32 i32] -> []`.
            .array_init_elem => {
                const ge = instr.imm.gc_elem;
                const f = self.module.arrayField(ge.type_index) orelse return error.UndefinedType;
                if (!f.mutable) return error.ImmutableField;
                if (ge.elem >= self.module.elements.len) return error.UndefinedElem;
                if (!subtypeOf(self.module, self.module.elements[ge.elem].elem_type, f.storage.unpacked())) return error.TypeMismatch;
                _ = try self.popExpect(.i32); // len
                _ = try self.popExpect(.i32); // src offset (elements)
                _ = try self.popExpect(.i32); // dst offset (elements)
                _ = try self.popExpect(V.concreteRef(true, .array, ge.type_index));
            },

            // GC casts. `ref.test` consumes a reference and yields i32; `ref.cast`
            // passes the reference through with the target's (collapsed) type,
            // trapping at runtime on a failed cast.
            // Spec: `ref.test rt : [rt.] -> [i32]` with `rt <: rt.` — the operand and
            // the target must share a TOP type. Popping any reference accepted
            // `ref.test (ref func)` on an `externref`. Contained at run time
            // (`refMatches` answers 0), so this is conformance.
            .ref_test => {
                _ = try self.popExpect((try refTypeValType(self.module, instr.imm.ref_cast)).refHeap().top().valType(true));
                try self.pushValT(.i32);
            },
            .ref_cast => {
                _ = try self.popExpect((try refTypeValType(self.module, instr.imm.ref_cast)).refHeap().top().valType(true));
                try self.pushValT(try refTypeValType(self.module, instr.imm.ref_cast));
            },

            // GC cast-branches. The label carries `[t* rt]` (the ref plus a prefix
            // `t*`); the operand is `[t* src]`. `br_on_cast` branches when the ref
            // matches `dst` (passing it as `dst`) and falls through otherwise;
            // `br_on_cast_fail` is the mirror. `dst` must be a subtype of `src`.
            .br_on_cast, .br_on_cast_fail => {
                const bc = instr.imm.br_cast;
                const src_vt = try refTypeValType(self.module, bc.src);
                const dst_vt = try refTypeValType(self.module, bc.dst);
                if (!subtypeOf(self.module, dst_vt, src_vt)) return error.TypeMismatch; // a downcast
                const lt = try self.labelTypesAt(bc.label); // [t* carried]
                if (lt.len == 0) return error.TypeMismatch;
                // `rt1 \ rt2` — the source type MINUS what the cast would have
                // caught. When the target is NULLABLE a null matches it, so a
                // value that fails the cast is non-null and the difference loses
                // nullability.
                const diff = if (dst_vt.isNonNullRef()) src_vt else src_vt.nonNull();
                // The type carried to the label: `dst` for br_on_cast (the branch
                // fires on a match), the DIFFERENCE for br_on_cast_fail (fires on
                // a miss).
                //
                // ⚠️ This used plain `src_vt` for the fail form. The subtraction
                // was already implemented eleven lines below for br_on_cast's
                // FALL-THROUGH — the same rule, applied on one of the two paths
                // that need it — so `null-diff`, the test named for exactly this,
                // was rejected: it branches `(ref null any)` into a label typed
                // `(ref any)`.
                const carried = if (instr.op == .br_on_cast) dst_vt else diff;
                if (!subtypeOf(self.module, carried, lt[lt.len - 1])) return error.TypeMismatch;
                const prefix = lt[0 .. lt.len - 1]; // t*
                _ = try self.popExpect(src_vt); // the ref operand (top)
                try self.popVals(prefix);
                try self.pushVals(prefix);
                // Fall-through leaves the ref: `src` for br_on_cast (not dst),
                // narrowed to `dst` for br_on_cast_fail (it is dst).
                // Spec: the fall-through type is `rt1  rt2`. When the cast target is
                // NULLABLE, a null would have branched, so the fall-through ref is
                // non-null — pushing `src_vt` unchanged over-approximated and
                // rejected valid code that feeds it to a `(ref …)` parameter.
                try self.pushValT(if (instr.op == .br_on_cast) diff else dst_vt);
            },

            // GC: the extern↔any bridge. Both are representation-preserving and
            // NULLABILITY-PRESERVING: `extern.convert_any` takes `(ref null? any)`
            // to `(ref null? extern)` and `any.convert_extern` the reverse, with
            // the null-ness carried across. Mirrors the const-expr arms, which
            // were the only place these existed until R10.
            .extern_convert_any => switch (try self.popRef()) {
                .val => |v| try self.pushValT(if (v.isNonNullRef()) .externref_nn else .externref),
                .unknown => try self.pushVal(.unknown),
            },
            .any_convert_extern => switch (try self.popRef()) {
                .val => |v| try self.pushValT(if (v.isNonNullRef()) .anyref_nn else .anyref),
                .unknown => try self.pushVal(.unknown),
            },

            // Spec: `[(ref null ht)] -> [(ref ht)]` — the op EXISTS to remove
            // nullability, but this pushed the operand back unchanged, so
            // `(func (param funcref) (result (ref func)) (ref.as_non_null …))` —
            // the canonical null-check idiom — was rejected TypeMismatch.
            .ref_as_non_null => switch (try self.popRef()) {
                .val => |v| try self.pushValT(v.nonNull()),
                .unknown => try self.pushVal(.unknown),
            },
            .br_on_null => {
                // Pop the ref; on branch pass [t*] to the label, on fall-through
                // keep the (now non-null) ref.
                const r = try self.popRef();
                const lt = try self.labelTypesAt(instr.imm.label);
                try self.popVals(lt);
                try self.pushVals(lt);
                // Fall-through means the ref was NOT null, so it narrows to the
                // non-nullable form (`br_on_null l : [t* (ref null ht)] -> [t* (ref ht)]`).
                // Re-pushing it unchanged rejected the canonical
                // `(call $use (br_on_null $b (local.get 0)))` idiom.
                switch (r) {
                    .val => |v| try self.pushValT(v.nonNull()),
                    .unknown => try self.pushVal(.unknown),
                }
            },
            .br_on_non_null => {
                // Spec (function-references):
                //   br_on_non_null l : [t* (ref null ht)] → [t*]
                //   where C.labels[l] = [t* (ref ht)]
                // so the label's last type must be a REFERENCE — any reference.
                // This used to hard-code `funcref`/`externref`, which wrongly
                // rejected every valid GC/typed label (`i31ref`, `anyref`,
                // `eqref`, `structref`, `arrayref`, a concrete `(ref $t)`) —
                // reject-valid, not a safety issue.
                const lt = try self.labelTypesAt(instr.imm.label);
                if (lt.len == 0 or !lt[lt.len - 1].isRef()) return error.TypeMismatch;
                // ⚠️ Pop the OPERAND first, and check only `t*` against the stack.
                // The label's last type is the NON-NULL `(ref ht)`; the operand is
                // its nullable counterpart `(ref null ht)`. Popping `lt` wholesale
                // therefore asked the stack for `(ref any)` where `anyref` sits —
                // "expected anyref_nn, found anyref" — and rejected the canonical
                // idiom this instruction exists for:
                //
                //     (block $l (result (ref any))
                //       (br_on_non_null $l (table.get …)) (return …))
                //
                // It cost the first module of `br_on_non_null.wast` AND of
                // `br_on_cast_fail.wast`, i.e. 33 assertions across two files.
                const r = try self.popRef();
                switch (r) {
                    .val => |v| if (!subtypeOf(self.module, v, lt[lt.len - 1].nullable()))
                        return error.TypeMismatch,
                    .unknown => {},
                }
                const prefix = lt[0 .. lt.len - 1];
                try self.popVals(prefix);
                try self.pushVals(prefix);
            },

            .local_get => {
                const t = try self.localAt(instr.imm.local);
                // A non-defaultable local must have been set on this path (unless
                // we're already in unreachable/polymorphic code).
                if (t.isNonNullRef() and !self.local_init[instr.imm.local] and !self.topUnreachable())
                    return error.UninitializedLocal;
                try self.pushValT(t);
            },
            .local_set => {
                _ = try self.popExpect(try self.localAt(instr.imm.local));
                self.local_init[instr.imm.local] = true;
            },
            .local_tee => {
                const t = try self.localAt(instr.imm.local);
                _ = try self.popExpect(t);
                self.local_init[instr.imm.local] = true;
                try self.pushValT(t);
            },
            .global_get => try self.pushValT((try self.globalAt(instr.imm.global)).content),
            .global_set => {
                const g = try self.globalAt(instr.imm.global);
                if (!g.mutable) return error.ImmutableGlobal;
                _ = try self.popExpect(g.content);
            },

            else => switch (opcode.immediateKind(instr.op)) {
                // Load/store: the alignment (log2) must not exceed the access's
                // natural alignment, the addressed memory must exist, and — for a
                // memory64 memory — the ADDRESS operand is i64, not i32.
                .mem => {
                    try self.requireMemory(instr.imm.mem.memory);
                    if (instr.imm.mem.alignment > opcode.naturalAlignLog2(instr.op)) return error.InvalidAlignment;
                    try self.checkMemOffset(instr.imm.mem.memory, instr.imm.mem.offset);
                    const s = simpleSig(instr.op) orelse return error.UnsupportedOpcode;
                    const at = self.memAddrTy(instr.imm.mem.memory);
                    // `pop` is `[addr]` (load) or `[addr, value]` (store). Pop the
                    // trailing value(s) top-first, then the address as `at`.
                    var k = s.pop.len;
                    while (k > 1) : (k -= 1) _ = try self.popExpect(s.pop[k - 1]);
                    _ = try self.popExpect(at);
                    try self.pushVals(s.push);
                },
                // `memory.size`/`memory.grow` reached `simpleSig` with no memory
                // check at all. For a memory64 memory the operand/result is i64.
                .mem_index => {
                    try self.requireMemory(instr.imm.mem_index);
                    const at = self.memAddrTy(instr.imm.mem_index);
                    if (instr.op == .memory_grow) _ = try self.popExpect(at); // delta
                    try self.pushValT(at); // size / new-or-old page count
                },
                else => {
                    const s = simpleSig(instr.op) orelse return error.UnsupportedOpcode;
                    try self.popVals(s.pop);
                    try self.pushVals(s.push);
                },
            },
        }
    }
};

/// True if two value-type lists are element-wise equal.
fn valTypesEqual(a: []const V, b: []const V) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// §3.3.8: a tail call's callee results must be a SUBTYPE SEQUENCE of the
/// caller's declared results — `[t2*] <: [t2'*]` — not equal to them.
///
/// ⚠️ All three tail-call forms used `valTypesEqual`, which is reject-VALID for
/// every widening return: `(func (result (ref null $t)) (return_call_ref $t1 …))`
/// where `$t1` returns the non-null `(ref $t)` is exactly the idiom
/// `return_call_ref.wast`'s "More typing" module is built from, and equality
/// refused six functions of it. Equality is not a conservative approximation of
/// subtyping here — it is a different rule that rejects real code.
fn resultsSubtype(module: *const Module, callee: []const V, caller: []const V) bool {
    if (callee.len != caller.len) return false;
    for (callee, caller) |x, y| if (!subtypeOf(module, x, y)) return false;
    return true;
}

/// Is `sub` a subtype of `sup` (for operand matching)? Identical types match.
/// Reference subtyping follows the WasmGC hierarchy on the heap type
/// (`RefHeap.sub`: i31/struct/array <: eq <: any; `none` the bottom; func/extern
/// disjoint) combined with nullability: a non-null reference is a subtype of the
/// nullable form (`(ref t) <: (ref null t)`), so a non-null value satisfies a
/// nullable expectation but not the reverse.
/// Enforce the packed/unpacked rule for a field accessor: the plain `*.get`
/// forms require an unpacked field; the `_s`/`_u` forms require a packed one.
fn requirePacking(is_plain_get: bool, storage: Module.StorageType) Error!void {
    if (is_plain_get == storage.isPacked()) return error.BadFieldPacking;
}

/// The value type of a cast target reference type — a concrete `(ref null? $t)`
/// keeps its type index; an abstract target uses its family head.
fn refTypeValType(module: *const Module, rt: opcode.RefType) Error!V {
    const head = try module.refHead(rt.heap);
    return switch (rt.heap) {
        .concrete => |ti| V.concreteRef(rt.nullable, head, ti),
        else => head.valType(rt.nullable),
    };
}

/// §3.3.9 — is a DECLARED supertype relation legitimate? `(type $s (sub $t …))`
/// only type-checks if `$s`'s structure *matches* `$t`'s.
///
/// ⚠️ **We never checked this at all.** The decoder recorded `supertypes[i]` and
/// the validator trusted it, so a module could declare any type the supertype of
/// any other and `isSubtype`'s chain walk would then agree — `(array i32)` under
/// `(array i64)`, a struct under a func, `(func)` under `(func (param i32))`.
/// Nineteen of `type-subtyping.wast`'s accept-invalid failures, and every one of
/// them makes `ref.cast`/`br_on_cast` unsound: the cast succeeds and the
/// interpreter then reads the value at a type it does not have.
fn declaredSubtypeOk(module: *const Module, sub_i: u32, sup_i: u32) bool {
    if (sup_i >= module.comp_types.len or sub_i >= module.comp_types.len) return false;
    // A final type is closed: nothing may name it as a supertype.
    if (module.isFinal(sup_i)) return false;
    const sub = module.comp_types[sub_i];
    const sup = module.comp_types[sup_i];
    return switch (sup) {
        // Function: params CONTRAVARIANT, results COVARIANT, arities equal.
        .func => |f_sup| switch (sub) {
            .func => |f_sub| blk: {
                if (f_sub.params.len != f_sup.params.len) break :blk false;
                if (f_sub.results.len != f_sup.results.len) break :blk false;
                for (f_sup.params, f_sub.params) |p_sup, p_sub|
                    if (!subtypeOf(module, p_sup, p_sub)) break :blk false; // note the order
                for (f_sub.results, f_sup.results) |r_sub, r_sup|
                    if (!subtypeOf(module, r_sub, r_sup)) break :blk false;
                break :blk true;
            },
            else => false, // kind mismatch: a struct/array is never a func subtype
        },
        // Struct: the subtype may ADD fields at the end, but every inherited
        // field must still match positionally.
        .@"struct" => |fs_sup| switch (sub) {
            .@"struct" => |fs_sub| blk: {
                if (fs_sub.len < fs_sup.len) break :blk false;
                for (fs_sup, fs_sub[0..fs_sup.len]) |f_sup, f_sub|
                    if (!fieldMatches(module, f_sub, f_sup)) break :blk false;
                break :blk true;
            },
            else => false,
        },
        .array => |f_sup| switch (sub) {
            .array => |f_sub| fieldMatches(module, f_sub, f_sup),
            else => false,
        },
    };
}

/// §3.3.8 field matching. A MUTABLE field is INVARIANT — it is both read and
/// written through the supertype, so widening it either way is unsound. An
/// immutable field is covariant, and cannot be re-opened as mutable.
fn fieldMatches(module: *const Module, sub: Module.FieldType, sup: Module.FieldType) bool {
    if (sub.mutable != sup.mutable) return false;
    if (sup.mutable) return storageEql(module, sub.storage, sup.storage);
    return storageSubtypeOf(module, sub.storage, sup.storage);
}

/// Storage-type IDENTITY (the invariant, mutable-field case).
///
/// Goes through `Module.valTypeEq` rather than `==` for the same reason
/// everything else in this pass does: a concrete `(ref $t)` carries a type index,
/// and two indices naming isomorphic rec groups are ONE type. Raw `==` rejected a
/// valid `(sub $parent (struct (field (mut (ref $t2)))))` whenever the parent
/// spelled the same field type through a different index.
fn storageEql(module: *const Module, a: Module.StorageType, b: Module.StorageType) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .val => |v| module.valTypeEq(v, b.val),
        .i8, .i16 => true,
    };
}

/// Packed storage types (`i8`/`i16`) relate only to themselves — `i8` is not a
/// subtype of `i16` or of `i32`, despite all three unpacking to `i32`.
fn storageSubtypeOf(module: *const Module, sub: Module.StorageType, sup: Module.StorageType) bool {
    if (sub == .val and sup == .val) return subtypeOf(module, sub.val, sup.val);
    return storageEql(module, sub, sup);
}

fn subtypeOf(module: *const Module, sub: V, sup: V) bool {
    if (sub == sup) return true;
    if (!sub.isRef() or !sup.isRef()) return false;
    // A nullable sub cannot satisfy a non-null expectation.
    if (sup.isNonNullRef() and !sub.isNonNullRef()) return false;
    // Concrete → concrete: walk the declared supertype chain (the collapsed
    // heads alone would wrongly accept any two structs / any two arrays).
    if (sub.isConcrete() and sup.isConcrete())
        return module.isSubtype(sub.concreteIndex(), sup.concreteIndex());
    // Abstract sup (or abstract sub): compare on the family hierarchy. A concrete
    // sub matches an abstract sup by its family head (`(ref $struct)` <: structref
    // / eqref / anyref); an abstract sub only satisfies a concrete sup when it is
    // the bottom `none`.
    if (sub.isConcrete()) return sub.refHeap().sub(sup.refHeap());
    if (sup.isConcrete()) return sub.refHeap() == .none;
    return sub.refHeap().sub(sup.refHeap());
}

/// True if an abstract stack entry is a concrete reference type (funcref /
/// externref). Unknown (polymorphic) entries are not — they can't be pinned.
fn isRefStack(st: StackType) bool {
    return switch (st) {
        .val => |v| v.isRef(),
        .unknown => false,
    };
}

// Common operand lists, in stack bottom→top order.
const empty: []const V = &.{};
const i32_1: []const V = &.{.i32};
const i32_2: []const V = &.{ .i32, .i32 };
const i64_1: []const V = &.{.i64};
const i64_2: []const V = &.{ .i64, .i64 };
const f32_1: []const V = &.{.f32};
const f32_2: []const V = &.{ .f32, .f32 };
const f64_1: []const V = &.{.f64};
const f64_2: []const V = &.{ .f64, .f64 };
const store_i64: []const V = &.{ .i32, .i64 }; // addr, value
const store_f32: []const V = &.{ .i32, .f32 };
const store_f64: []const V = &.{ .i32, .f64 };
const v128_1: []const V = &.{.v128};
const v128_2: []const V = &.{ .v128, .v128 };
const v128_3: []const V = &.{ .v128, .v128, .v128 };
const v128_shift: []const V = &.{ .v128, .i32 }; // vector, shift amount
const addr_v128: []const V = &.{ .i32, .v128 }; // store / lane load-store: addr, vector

fn sig(pop: []const V, push: []const V) FuncValidator.Sig {
    return .{ .pop = pop, .push = push };
}

/// Value-type signature of a `0xFD` SIMD op (by sub-opcode). Total — an
/// unclassified op defaults to the common binary shape `v128,v128 -> v128`;
/// that only affects functions using unimplemented ops, which trap at execution
/// before the annotation is used (see `interp` drop/select width handling).
/// The value type (`i32`/`i64`) an atomic load/store/rmw/cmpxchg operates on.
/// Determined by the sub-opcode: the `i32.*`/`i64.*` prefix in the mnemonic.
fn atomicValType(sub: u32) V {
    return switch (sub) {
        0x10, 0x12, 0x13, 0x17, 0x19, 0x1a => .i32, // i32 loads/stores (full/8/16)
        0x11, 0x14, 0x15, 0x16, 0x18, 0x1b, 0x1c, 0x1d => .i64, // i64 loads/stores
        // rmw/cmpxchg groups of 7: [i32.full, i64.full, i32.8, i32.16, i64.8,
        // i64.16, i64.32] — positions 0,2,3 are i32; 1,4,5,6 are i64.
        else => switch ((sub - 0x1e) % 7) {
            0, 2, 3 => .i32,
            else => .i64,
        },
    };
}

fn simdSig(sub: u32) FuncValidator.Sig {
    return switch (sub) {
        0x00...0x0a, 0x5c, 0x5d => sig(i32_1, v128_1), // loads: addr -> v128
        0x0b => sig(addr_v128, empty), // v128.store
        0x54...0x57 => sig(addr_v128, v128_1), // load lane
        0x58...0x5b => sig(addr_v128, empty), // store lane
        0x0c => sig(empty, v128_1), // v128.const
        0x0d, 0x0e => sig(v128_2, v128_1), // shuffle / swizzle
        0x0f, 0x10, 0x11 => sig(i32_1, v128_1), // i8/i16/i32 splat
        0x12 => sig(i64_1, v128_1), // i64x2.splat
        0x13 => sig(f32_1, v128_1), // f32x4.splat
        0x14 => sig(f64_1, v128_1), // f64x2.splat
        0x15, 0x16, 0x18, 0x19, 0x1b => sig(v128_1, i32_1), // extract_lane -> i32
        0x1d => sig(v128_1, i64_1),
        0x1f => sig(v128_1, f32_1),
        0x21 => sig(v128_1, f64_1),
        0x17, 0x1a, 0x1c => sig(&.{ .v128, .i32 }, v128_1), // replace_lane
        0x1e => sig(&.{ .v128, .i64 }, v128_1),
        0x20 => sig(&.{ .v128, .f32 }, v128_1),
        0x22 => sig(&.{ .v128, .f64 }, v128_1),
        0x23...0x4c => sig(v128_2, v128_1), // comparisons
        0x4d => sig(v128_1, v128_1), // v128.not
        0x4e...0x51 => sig(v128_2, v128_1), // and/andnot/or/xor
        0x52, 0x105...0x10c, 0x113 => sig(v128_3, v128_1), // bitselect + relaxed madd/nmadd/laneselect/dot_add
        0x53, 0x63, 0x83, 0xa3, 0xc3 => sig(v128_1, i32_1), // any_true / all_true
        0x64, 0x84, 0xa4, 0xc4 => sig(v128_1, i32_1), // bitmask
        0x6b...0x6d, 0x8b...0x8d, 0xab...0xad, 0xcb...0xcd => sig(v128_shift, v128_1), // shifts
        // unary v128 -> v128: abs/neg/popcnt, sqrt, ceil/floor/trunc/nearest,
        // extend low/high, extadd_pairwise, int<->float convert, trunc_sat,
        // promote/demote. (Arity here must match the interpreter, or the
        // drop/select width tracking downstream mis-counts v128 operands.)
        0x60, 0x61, 0x62, 0x80, 0x81, 0xa0, 0xa1, 0xc0, 0xc1, 0xe0, 0xe1, 0xe3, 0xec, 0xed, 0xef, 0x67, 0x68, 0x69, 0x6a, 0x74, 0x75, 0x7a, 0x94, 0x87, 0x88, 0x89, 0x8a, 0xa7, 0xa8, 0xa9, 0xaa, 0xc7, 0xc8, 0xc9, 0xca, 0x7c, 0x7d, 0x7e, 0x7f, 0x5e, 0x5f, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff, 0x101, 0x102, 0x103, 0x104 => sig(v128_1, v128_1), // (incl. relaxed_trunc)
        else => sig(v128_2, v128_1), // default: binary lane arithmetic (incl. relaxed swizzle/min/max/q15/dot)
    };
}

/// Fixed value-type signature for the numeric / comparison / conversion /
/// const / load / store / memory opcodes. Returns null for opcodes handled
/// specially in `step` (control flow, variable, call, drop, select).
fn simpleSig(op: Op) ?FuncValidator.Sig {
    return switch (@intFromEnum(op)) {
        // Comparisons
        0x45 => sig(i32_1, i32_1), // i32.eqz
        0x46...0x4f => sig(i32_2, i32_1),
        0x50 => sig(i64_1, i32_1), // i64.eqz
        0x51...0x5a => sig(i64_2, i32_1),
        0x5b...0x60 => sig(f32_2, i32_1),
        0x61...0x66 => sig(f64_2, i32_1),
        // Numeric
        0x67...0x69 => sig(i32_1, i32_1), // i32 clz/ctz/popcnt
        0x6a...0x78 => sig(i32_2, i32_1), // i32 binops
        0x79...0x7b => sig(i64_1, i64_1), // i64 clz/ctz/popcnt
        0x7c...0x8a => sig(i64_2, i64_1), // i64 binops
        0x8b...0x91 => sig(f32_1, f32_1), // f32 unops
        0x92...0x98 => sig(f32_2, f32_1), // f32 binops
        0x99...0x9f => sig(f64_1, f64_1), // f64 unops
        0xa0...0xa6 => sig(f64_2, f64_1), // f64 binops
        // Conversions
        0xa7 => sig(i64_1, i32_1), // i32.wrap_i64
        0xa8, 0xa9 => sig(f32_1, i32_1), // i32.trunc_f32
        0xaa, 0xab => sig(f64_1, i32_1), // i32.trunc_f64
        0xac, 0xad => sig(i32_1, i64_1), // i64.extend_i32
        0xae, 0xaf => sig(f32_1, i64_1), // i64.trunc_f32
        0xb0, 0xb1 => sig(f64_1, i64_1), // i64.trunc_f64
        // Saturating truncation (internal tags for `0xFC 0x00–0x07`).
        0xc5, 0xc6 => sig(f32_1, i32_1), // i32.trunc_sat_f32_s/u
        0xc7, 0xc8 => sig(f64_1, i32_1), // i32.trunc_sat_f64_s/u
        0xc9, 0xca => sig(f32_1, i64_1), // i64.trunc_sat_f32_s/u
        0xcb, 0xcc => sig(f64_1, i64_1), // i64.trunc_sat_f64_s/u
        0xb2, 0xb3 => sig(i32_1, f32_1), // f32.convert_i32
        0xb4, 0xb5 => sig(i64_1, f32_1), // f32.convert_i64
        0xb6 => sig(f64_1, f32_1), // f32.demote_f64
        0xb7, 0xb8 => sig(i32_1, f64_1), // f64.convert_i32
        0xb9, 0xba => sig(i64_1, f64_1), // f64.convert_i64
        0xbb => sig(f32_1, f64_1), // f64.promote_f32
        0xbc => sig(f32_1, i32_1), // i32.reinterpret_f32
        0xbd => sig(f64_1, i64_1), // i64.reinterpret_f64
        0xbe => sig(i32_1, f32_1), // f32.reinterpret_i32
        0xbf => sig(i64_1, f64_1), // f64.reinterpret_i64
        // Sign extension
        0xc0, 0xc1 => sig(i32_1, i32_1),
        0xc2, 0xc3, 0xc4 => sig(i64_1, i64_1),
        // Constants
        0x41 => sig(empty, i32_1),
        0x42 => sig(empty, i64_1),
        0x43 => sig(empty, f32_1),
        0x44 => sig(empty, f64_1),
        // Loads: [i32 addr] -> [value]
        0x28, 0x2c, 0x2d, 0x2e, 0x2f => sig(i32_1, i32_1), // i32.load / load8 / load16
        0x29, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35 => sig(i32_1, i64_1), // i64.load*
        0x2a => sig(i32_1, f32_1), // f32.load
        0x2b => sig(i32_1, f64_1), // f64.load
        // Stores: [i32 addr, value] -> []
        0x36, 0x3a, 0x3b => sig(i32_2, empty), // i32.store / store8 / store16
        0x37, 0x3c, 0x3d, 0x3e => sig(store_i64, empty), // i64.store*
        0x38 => sig(store_f32, empty), // f32.store
        0x39 => sig(store_f64, empty), // f64.store
        // Memory
        0x3f => sig(empty, i32_1), // memory.size
        0x40 => sig(i32_1, i32_1), // memory.grow
        else => null,
    };
}

// --- Tests -----------------------------------------------------------------

test "validates a well-typed add function" {
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00 } ++
        [_]u8{ 0x0a, 0x0b, 0x01, 0x09, 0x01, 0x01, 0x7f, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try validate(std.testing.allocator, &m);
}

test "rejects memory.init/data.drop with no data-count section (§5.5.16)" {
    // A module with a memory, one passive data segment and a body that uses it,
    // but NO data-count section. Every index resolves — `data.len` is 1 — so
    // nothing downstream noticed; §5.5.16 still requires the section, because a
    // single-pass decoder must know the segment count before the code section.
    //
    // The mirror-image half of this gap lived in the ASSEMBLER, which emitted
    // the section never: fixing only the check here turned ~96 previously
    // passing corpus assertions red. Both halves are needed, and each one hid
    // the other.
    const with_count = [_]u8{ 0x0c, 0x01, 0x01 }; // data_count: 1 segment
    const rest =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++ // type: () -> ()
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++ // one func of type 0
        [_]u8{ 0x05, 0x03, 0x01, 0x00, 0x01 }; // memory: min 1 page
    // code(14) = count(1) + size(1) + body(12); body(12) = locals(1) + three
    // `i32.const 0`(2 each) + `memory.init 0 0`(4) + end(1).
    const tail =
        [_]u8{ 0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xfc, 0x08, 0x00, 0x00, 0x0b } ++
        // data(4) = count(1) + flags(1) + len(1) + "a"(1): one passive segment.
        [_]u8{ 0x0b, 0x04, 0x01, 0x01, 0x01, 0x61 };

    {
        const bytes = rest ++ tail;
        var m = try Module.decode(std.testing.allocator, &bytes);
        defer m.deinit();
        try std.testing.expectError(error.DataCountRequired, validate(std.testing.allocator, &m));
    }
    // The same module WITH the section must validate — the check must key on the
    // section's presence, not on `data.len`, which is 1 either way.
    {
        const bytes = rest ++ with_count ++ tail;
        var m = try Module.decode(std.testing.allocator, &bytes);
        defer m.deinit();
        try validate(std.testing.allocator, &m);
    }
}

test "rejects a stack underflow (i32.add with no operands)" {
    // type ()->() ; one func ; body: i32.add end
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x05, 0x01, 0x03, 0x00, 0x6a, 0x0b };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectError(error.StackUnderflow, validate(std.testing.allocator, &m));
}

test "rejects a result type mismatch (returns f32 for i32)" {
    // type ()->(i32) ; body: f32.const 0 end  -> end expects [i32], finds [f32]
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f } ++ // ()->(i32)
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        // body: f32.const 0x00000000 (0x43 00 00 00 00) end
        [_]u8{ 0x0a, 0x09, 0x01, 0x07, 0x00, 0x43, 0x00, 0x00, 0x00, 0x00, 0x0b };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(std.testing.allocator, &m));
}

test "rejects function/code count mismatch" {
    // function section declares 1 func, but no code section
    const bytes =
        types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 };
    var m = try Module.decode(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectError(error.CountMismatch, validate(std.testing.allocator, &m));
}

test "resource caps: a huge locals run and deep nesting are refused, not expanded" {
    // Both are amplifiers a tiny module can trigger, and the snapshot cost is
    // their PRODUCT (each control frame dupes the whole local-init vector).
    // Before the caps, a 512 KB module drove ~767 MB peak on the inspect path.
    const gpa = std.testing.allocator;

    // (func) with one locals run of count 0xFFFFFFFF — 37 bytes total.
    const many_locals = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 } ++
        [_]u8{ 0x03, 0x02, 0x01, 0x00 } ++
        [_]u8{ 0x0a, 0x0a, 0x01, 0x08, 0x01, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x7f, 0x0b };
    {
        var m = try Module.decode(gpa, &many_locals);
        defer m.deinit();
        try std.testing.expectError(error.TooManyLocals, validate(gpa, &m));
    }

    // A body of `block` × (max_ctrl_depth + 1) then matching `end`s.
    {
        const depth = max_ctrl_depth + 1;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try body.append(gpa, 0x00); // no locals
        for (0..depth) |_| try body.appendSlice(gpa, &.{ 0x02, 0x40 }); // block (empty type)
        for (0..depth) |_| try body.append(gpa, 0x0b); // end
        try body.append(gpa, 0x0b); // function's own end

        var sec: std.ArrayList(u8) = .empty;
        defer sec.deinit(gpa);
        try sec.append(gpa, 0x01); // one body
        var lenbuf: [5]u8 = undefined;
        var n: usize = 0;
        var v: u32 = @intCast(body.items.len);
        while (true) : (n += 1) { // uleb128
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            lenbuf[n] = if (v != 0) b | 0x80 else b;
            if (v == 0) break;
        }
        try sec.appendSlice(gpa, lenbuf[0 .. n + 1]);
        try sec.appendSlice(gpa, body.items);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
        try bytes.appendSlice(gpa, &.{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 });
        try bytes.appendSlice(gpa, &.{ 0x03, 0x02, 0x01, 0x00 });
        try bytes.append(gpa, 0x0a);
        var slen: [5]u8 = undefined;
        var sn: usize = 0;
        var sv: u32 = @intCast(sec.items.len);
        while (true) : (sn += 1) {
            const b: u8 = @intCast(sv & 0x7f);
            sv >>= 7;
            slen[sn] = if (sv != 0) b | 0x80 else b;
            if (sv == 0) break;
        }
        try bytes.appendSlice(gpa, slen[0 .. sn + 1]);
        try bytes.appendSlice(gpa, sec.items);

        var m = try Module.decode(gpa, bytes.items);
        defer m.deinit();
        try std.testing.expectError(error.NestingTooDeep, validate(gpa, &m));
    }
}

test "validator: memory-touching ops require an in-range memory" {
    // SIMD load/store and memory.size/grow reached the operand-typing path with
    // no memory check at all, so they validated in a module with **no memory**.
    // Contained at run time by `Frame.memBytes`, but `validate` is the gate an
    // embedder calling `wasm_module_validate` relies on.
    const gpa = std.testing.allocator;
    const wat = @import("wat.zig");

    const cases = [_]struct { src: []const u8, ok: bool }{
        // v128.load with no memory → invalid; with one → valid.
        .{ .src = "(module (func (export \"f\") (result v128) (v128.load (i32.const 0))))", .ok = false },
        .{ .src = "(module (memory 1) (func (export \"f\") (result v128) (v128.load (i32.const 0))))", .ok = true },
        // memory.size / memory.grow with no memory → invalid.
        .{ .src = "(module (func (export \"f\") (result i32) memory.size))", .ok = false },
        .{ .src = "(module (memory 1) (func (export \"f\") (result i32) memory.size))", .ok = true },
        // A scalar load still behaves.
        .{ .src = "(module (func (export \"f\") (result i32) (i32.load (i32.const 0))))", .ok = false },
        .{ .src = "(module (memory 1) (func (export \"f\") (result i32) (i32.load (i32.const 0))))", .ok = true },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const bin = try wat.assemble(arena.allocator(), c.src);
        var m = try Module.decode(gpa, bin);
        defer m.deinit();
        if (c.ok) {
            try validate(gpa, &m);
        } else {
            try std.testing.expectError(error.MissingMemory, validate(gpa, &m));
        }
    }
}

test "validator rejects legacy try/delegate (deprecated, no reference impl to verify routing)" {
    // `delegate` re-raises "at label l", which can skip intermediate handlers.
    // The interpreter records the label but never routes through it, and there is
    // no reference implementation left to validate the label arithmetic against
    // (wasmtime and V8 dropped the legacy EH encoding). We reject it rather than
    // accept a construct we cannot correctly execute. The assembler already
    // refuses `delegate`, so this binary is hand-built:
    //   (func (try (do) (delegate 0)))  →  try_ 0x40  delegate 0  end
    const gpa = std.testing.allocator;
    const bin = types.magic ++ [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x03, 0x02, 0x01, 0x00, //             function: one func, type 0
        0x0a, 0x08, 0x01, 0x06, 0x00, //       code: one body, size 6, 0 locals
        0x06, 0x40, //                         try (empty block type)
        0x18, 0x00, //                         delegate 0
        0x0b, //                               end (function)
    };
    var m = try Module.decode(gpa, &bin);
    defer m.deinit();
    try std.testing.expectError(error.UnsupportedOpcode, validate(gpa, &m));
}

test "validator: ref.func in a body requires the function to be declared (C.refs)" {
    // §3.4.10 "undeclared function reference". We type-checked that the funcidx
    // EXISTS but never that it was declared, so a body could forge a reference
    // to any function in the module — including one the module deliberately
    // kept unexported and unreferenced.
    const gpa = std.testing.allocator;
    const wat = @import("wat.zig");

    const cases = [_]struct { src: []const u8, ok: bool }{
        // Nothing outside the code section mentions $f -> undeclared.
        .{ .src = "(module (func $f) (func (export \"g\") (result funcref) (ref.func $f)))", .ok = false },
        // Each of the three declaring positions in turn.
        .{ .src = "(module (func $f) (elem declare func $f) (func (export \"g\") (result funcref) (ref.func $f)))", .ok = true },
        .{ .src = "(module (func $f) (export \"f\" (func $f)) (func (export \"g\") (result funcref) (ref.func $f)))", .ok = true },
        .{ .src = "(module (func $f) (global funcref (ref.func $f)) (func (export \"g\") (result funcref) (ref.func $f)))", .ok = true },
        // ⚠️ The START function is NOT one of them, and this case asserted that it
        // was until R4 (2026-08-13) — the test encoded the same wrong rule as the
        // code and the comment above it ("four declaring positions"), so all three
        // agreed and none of them was evidence. §3.5.1 erases `start` alongside the
        // function section when building `C.refs`; `ref_func.wast` requires this
        // module rejected.
        .{ .src = "(module (func $f) (start $f) (func (export \"g\") (result funcref) (ref.func $f)))", .ok = false },
        // An ACTIVE segment declares it just as well as a declarative one.
        .{ .src = "(module (func $f) (table 1 funcref) (elem (i32.const 0) $f) (func (export \"g\") (result funcref) (ref.func $f)))", .ok = true },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const bin = try wat.assemble(arena.allocator(), c.src);
        var m = try Module.decode(gpa, bin);
        defer m.deinit();
        if (c.ok) {
            try validate(gpa, &m);
        } else {
            try std.testing.expectError(error.UndeclaredFuncRef, validate(gpa, &m));
        }
    }
}

test "validator: br_on_non_null accepts any reference label type" {
    // The label's last type must be a REFERENCE (spec: C.labels[l] = [t* (ref ht)]).
    // This used to hard-code funcref/externref, wrongly rejecting every valid
    // GC/typed-ref label — reject-valid, not a safety issue.
    const gpa = std.testing.allocator;
    const wat = @import("wat.zig");

    const cases = [_]struct { src: []const u8, ok: bool }{
        // `(elem declare …)` puts $g in C.refs so the body may `ref.func` it.
        .{ .src = "(module (func $g) (elem declare func $g) (func (export \"f\") (result funcref) (block (result funcref) (br_on_non_null 0 (ref.func $g)) (ref.null func))))", .ok = true },
        // i31ref: a valid GC label that the old check rejected.
        .{ .src = "(module (func (export \"f\") (param i31ref) (result i31ref) (block (result i31ref) (br_on_non_null 0 (local.get 0)) (ref.null i31))))", .ok = true },
        .{ .src = "(module (func (export \"f\") (param anyref) (result anyref) (block (result anyref) (br_on_non_null 0 (local.get 0)) (ref.null any))))", .ok = true },
        // A non-reference label type is still invalid.
        .{ .src = "(module (func (export \"f\") (result i32) (block (result i32) (br_on_non_null 0 (ref.null func)) (i32.const 1))))", .ok = false },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const bin = try wat.assemble(arena.allocator(), c.src);
        var m = try Module.decode(gpa, bin);
        defer m.deinit();
        if (c.ok) {
            try validate(gpa, &m);
        } else {
            try std.testing.expectError(error.TypeMismatch, validate(gpa, &m));
        }
    }
}
