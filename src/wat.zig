//! WAT text → wasm binary assembler (the reverse of `Module.decode`).
//!
//! Parses a `(module …)` S-expression (via `sexpr.zig`) and encodes it to a
//! WebAssembly binary that the decoder/validator/interpreter consume. It reuses
//! `opcode.zig` as the single instruction authority: instruction names map to
//! `Op` via `stringToEnum` (dots → underscores), and each operand is encoded per
//! `opcode.immediateKind`.
//!
//! **Scope today:** `(func …)` with named/anonymous params/results/locals, inline
//! and top-level `(export …)`, the full non-control instruction set, structured
//! control flow (`block`/`loop`/`if`, `br*`) with single-result/multi-value/
//! type-index block types, memory + data, tables (funcref/externref) + `elem` +
//! `call_indirect`, the reference-type table ops (`table.get`/`.set`/`.size`/
//! `.grow`/`.fill`), globals (`(global (mut? t) init)`, incl. imported globals +
//! extended-const inits, `global.get`/`.set`), and reference types
//! (`ref.null`/`ref.is_null`/`ref.func`, `(ref null? func|extern)`) — in both
//! folded `(i32.add (local.get 0) (local.get 1))` and flat forms.
//!
//! Also assembled (missing from this header until 2026-07-21): `(start …)`,
//! **imported functions/tables/memories**, the bulk table ops (`table.init`/
//! `.copy`, `elem.drop`), the **complete SIMD set**, **GC**, and **exception
//! handling** (`emitTryTable`). The old header listed the first three as
//! "Deferred" long after they shipped.
//!
//! Genuinely deferred: multi-memory in the text syntax, and legacy
//! `try`/`catch` (decode + execute only — no assembler support).

const std = @import("std");
const sexpr = @import("sexpr.zig");
const opcode = @import("opcode.zig");
const types = @import("types.zig");

const V = types.ValType;
const Op = opcode.Op;
const Sexpr = sexpr.Sexpr;
const List = std.ArrayList;

pub const Error = sexpr.Error || error{
    NotAModule,
    BadModuleField,
    BadValType,
    UnknownInstr,
    UnknownIdentifier,
    BadImmediate,
    UnsupportedInstr,
    /// An `import` (top-level or inline) after a func/table/memory/global
    /// definition — malformed: imports must precede all definitions (§6.6.13).
    ImportAfterDefinition,
    /// Syntax wazmrt RECOGNISES as belonging to a wasm proposal it does not
    /// target — today only `(memory … (pagesize N))` (custom-page-sizes).
    ///
    /// Distinct from `BadModuleField` on purpose. The module may be perfectly
    /// valid under its proposal, so refusing it is *our* gap, not a verdict on
    /// the module; `wast.zig`'s `isOurLimitation` therefore scores it as a SKIP
    /// rather than banking it as a conformance pass.
    UnsupportedProposal,
} || std.mem.Allocator.Error;

// --- Shape-checked s-expression accessors -----------------------------------
// The parser only balances parens/strings; it does NOT validate that a form has
// the shape the assembler expects. Malformed `.wat` must therefore yield
// `error.BadModuleField`, never an unchecked `items[N]` OOB read or a
// wrong-union `.?`/`.string` deref (both UB in the shipped ReleaseFast build).
// Every access derived from parser output goes through these.

fn wantList(s: Sexpr) Error![]const Sexpr {
    return s.asList() orelse error.BadModuleField;
}
fn wantAtom(s: Sexpr) Error![]const u8 {
    return s.asAtom() orelse error.BadModuleField;
}
fn wantStr(s: Sexpr) Error![]const u8 {
    return switch (s) {
        .string => |x| x,
        else => error.BadModuleField,
    };
}

/// Cap on the synthesized element copies for `(table N reftype initexpr)`. `N`
/// is attacker-written text and each copy is an `Sexpr`, so an unbounded `N`
/// turns 48 bytes into a request for tens of GB. 2^20 entries is far beyond any
/// real table literal.
const max_table_init_copies: u32 = 1 << 20;
/// The i-th element of a form, or `error.BadModuleField` if the form is too short.
fn nth(items: []const Sexpr, i: usize) Error!Sexpr {
    return if (i < items.len) items[i] else error.BadModuleField;
}
/// The i-th field of a sub-form `s` as a string (e.g. `(export "name")` → i=1),
/// shape-checked end to end: `s` must be a list, long enough, with a string there.
fn fieldStr(s: Sexpr, i: usize) Error![]const u8 {
    return wantStr(try nth(try wantList(s), i));
}
/// The i-th element of an already-unwrapped form as a string (`items[i].string`).
fn strAt(items: []const Sexpr, i: usize) Error![]const u8 {
    return wantStr(try nth(items, i));
}

const Func = struct {
    name: ?[]const u8 = null,
    params: List(V) = .empty,
    results: List(V) = .empty,
    locals: List(V) = .empty,
    /// Names of params then locals, index-aligned (null = anonymous).
    local_names: List(?[]const u8) = .empty,
    /// Inline export names (`(func (export "x") …)`).
    exports: List([]const u8) = .empty,
    /// `(type $t)` reference, if the function declares its type by index.
    type_ref: ?Sexpr = null,
    /// Inline import (`(func $id (import "m" "n") typeuse)`) — no body.
    import: ?struct { module: []const u8, name: []const u8 } = null,
    /// Body instruction forms (everything after the param/result/local headers).
    body: []const Sexpr = &.{},
};

/// An imported function (top-level `(import "m" "n" (func …))` or inline
/// `(func (import "m" "n") …)`); its type is `type_ref` or the inline sig.
const ImportedFunc = struct { module: []const u8, name: []const u8, type_ref: ?Sexpr, params: []const V, results: []const V };

const ExportDef = struct { name: []const u8, kind: u8, index: u32 };
/// A parsed data segment: `offset_form == null` is passive; otherwise active
/// (at `mem_index`, always 0 — the single supported memory) with that offset
/// const-expr. `offset_form` may be `(offset …)`, a folded `(i32.const …)`, or
/// `(global.get …)`.
const DataSeg = struct { mem_index: u32, offset_form: ?Sexpr, bytes: []const u8 };
/// A function type (for the type section): params → results.
const Sig = struct {
    params: []const V,
    results: []const V,
    /// True for the slot a struct/array type definition occupies. `sigs` is
    /// index-aligned with the type section, so GC definitions reserve a slot with
    /// an empty placeholder signature — and `internSig` would otherwise hand an
    /// implicit `() -> ()` FUNCTION signature the STRUCT's index, making the
    /// function section point at a non-func type (`BadType` at decode). It only
    /// worked when a real `(func)` type happened to be declared first.
    gc_placeholder: bool = false,
};

/// A GC struct field / array element (assembler side): storage type + mutability.
const GcStorage = union(enum) { val: V, i8, i16 };
const GcField = struct { storage: GcStorage, mutable: bool };
/// The composite kind of a named `(type …)` definition. Func types keep their
/// signature in the parallel `sigs` list (index-aligned); struct/array carry
/// their fields here. Interned block-type/func sigs (beyond the named types)
/// are implicitly `.func`.
const GcTypeDef = union(enum) { func, @"struct": []const GcField, array: GcField };
const TableDef = struct { min: u32, max: ?u32, elem: V = .funcref };
/// An element segment. `funcs` (func-index form) OR `exprs` (const-expr form) —
/// exactly one is non-empty. `offset` applies only to active segments.
const ElemDef = struct {
    mode: enum { active, passive, declarative },
    table_index: u32,
    /// Offset const-expr form for active segments (null → implicit `i32.const 0`).
    offset_form: ?Sexpr,
    elem_type: V,
    expr_form: bool,
    funcs: []const Sexpr,
    exprs: []const Sexpr,
};
/// A defined global: its value type, mutability, and (unencoded) init
/// const-expr — a *sequence* of instruction forms (usually one folded expr, but
/// a malformed module may list several, which validation then rejects on arity).
const GlobalDef = struct { valtype: V, mutable: bool, init: []const Sexpr };
/// An imported global (`(global (import "m" "n") type)`).
const ImportedGlobal = struct { module: []const u8, name: []const u8, valtype: V, mutable: bool };
const ImportedTable = struct { module: []const u8, name: []const u8, min: u32, max: ?u32, elem: V };
const ImportedMemory = struct { module: []const u8, name: []const u8, min: u64, max: ?u64, shared: bool = false, is64: bool = false };
const ImportedTag = struct { module: []const u8, name: []const u8, sig: u32 };

/// Assemble the first `(module …)` form found in `src`.
pub fn assemble(a: std.mem.Allocator, src: []const u8) Error![]const u8 {
    for (try sexpr.parseAll(a, src)) |form| {
        if (form.keyword()) |kw| {
            if (std.mem.eql(u8, kw, "module")) return assembleModule(a, (try wantList(form)));
        }
    }
    return error.NotAModule;
}

/// Assemble a parsed `(module …)` form (`module[0]` is the `module` keyword).
pub fn assembleModule(a: std.mem.Allocator, module: []const Sexpr) Error![]const u8 {
    var funcs: List(Func) = .empty;
    var func_names: List(?[]const u8) = .empty;
    var exports: List(ExportDef) = .empty;
    var datas: List(DataSeg) = .empty;
    // Data-segment names (index-aligned with `datas`). Data was the only index
    // space with no name table, so `memory.init $d` / `data.drop $d` were a hard
    // `BadImmediate` while the sibling `elem.drop $e` / `table.init $e` resolved
    // fine — an asymmetry with no reason behind it.
    var data_names: List(?[]const u8) = .empty;
    // Module-level `(export …)` forms, resolved after every field is parsed so a
    // forward reference works (see the `export` arm).
    var pending_exports: List([]const Sexpr) = .empty;
    var tables: List(TableDef) = .empty;
    var table_names: List(?[]const u8) = .empty;
    var elems: List(ElemDef) = .empty;
    var elem_names: List(?[]const u8) = .empty;
    var sigs: List(Sig) = .empty;
    var type_names: List(?[]const u8) = .empty;
    // Exception tags (EH proposal): each names a type index (its params are the
    // exception's value types). `tag_types` holds the DEFINED tags (the tag
    // section); imported tags live in `tag_imports`. `tag_names` spans BOTH —
    // imports first, definitions after — so `$e` resolution yields the right
    // global tag index (imports take the low indices, mirroring memories).
    var tag_types: List(u32) = .empty;
    var tag_imports: List(ImportedTag) = .empty;
    var tag_names: List(?[]const u8) = .empty;
    // GC composite kinds, index-aligned with the leading named `(type …)` defs
    // in `sigs`; struct/array carry their fields (func types use `sigs`).
    var gc_types: List(GcTypeDef) = .empty;
    // Field names of each named type, index-aligned with `gc_types` (empty for
    // func/array; a struct's entry is index-aligned with its fields, `null` for
    // an anonymous field). Lets `struct.get $T $field` resolve a field by name,
    // not just by number — the form binaryen/wat-tools and hand-written GC .wat
    // actually emit.
    var gc_field_names: List([]const ?[]const u8) = .empty;
    // Declared supertype (`(sub $super …)`) of each named type, or null; resolved
    // against `type_names` at type-section emission.
    var gc_supers: List(?Sexpr) = .empty;
    // Whether each named GC type is FINAL (closed to extension) — true unless
    // the source wrote `sub` without `final`. Index-aligned with `gc_supers`.
    var gc_finals: List(bool) = .empty;
    var globals: List(GlobalDef) = .empty;
    var global_imports: List(ImportedGlobal) = .empty;
    var table_imports: List(ImportedTable) = .empty;
    var mem_imports: List(ImportedMemory) = .empty;
    // Imports are collected into per-kind lists (which drive the per-kind index
    // spaces), but the import SECTION must list them in source order — that order
    // is the linking ABI a positional embedder (`wasm_instance_new`) builds its
    // extern vector against. Recording the kind of each import as it is parsed
    // lets the section be emitted in declaration order while the per-kind lists
    // still assign indices. Each import-bearing field adds exactly one import, so
    // one tag per grown list per field.
    const ImportTag = enum { func, table, mem, global, tag };
    var import_order: List(ImportTag) = .empty;
    var global_names: List(?[]const u8) = .empty;
    var func_imports: List(ImportedFunc) = .empty;
    // Defined memories (multi-memory). Each `(memory …)` appends here; the memory
    // section emits them in order. Imported memories take the low indices, so
    // `mem_names` (below) spans BOTH — imports first, definitions after.
    var memories: List(struct { min: u64, max: ?u64, shared: bool = false, is64: bool = false }) = .empty;
    // Memory names, index-aligned with the memory INDEX space (imported memories
    // first, then defined). Lets a `$name` resolve everywhere it can appear:
    // `(export "m" (memory $x))`, `(i32.load $x …)`, `memory.size $x`,
    // `(data (memory $x) …)`. Before multi-memory this was a single optional name
    // and any index but 0 was refused.
    var mem_names: List(?[]const u8) = .empty;
    var start_ref: ?Sexpr = null;

    const start: usize = if (module.len > 1 and isId(module[1])) 2 else 1; // skip optional module $name

    // Pre-pass A: collect every `(type …)` name first (a concrete `(ref $t)` in a
    // field/param may forward-reference a later type, e.g. within a `(rec …)`
    // group — the assembler emits them ungrouped, the decoder flattens the same).
    var type_forms: List([]const Sexpr) = .empty;
    // Size of each declared type group, in order — 1 for a standalone `(type …)`.
    //
    // ⚠️ **The grouping is part of the TYPE, not layout.** Two types are the same
    // only if their whole rec groups are isomorphic *and* they sit at the same
    // position, so `(rec (func) (struct))` and `(rec (struct) (func))` define
    // four distinct types. We flattened `(rec …)` away here and emitted the
    // members ungrouped, which silently rewrote the module into a different one
    // — every member became its own singleton group, and structurally identical
    // members then collapsed together. `type-rec.wast` catches it five ways.
    var rec_sizes: List(u32) = .empty;
    for (module[start..]) |field| {
        const kw = field.keyword() orelse continue;
        if (std.mem.eql(u8, kw, "type")) {
            try type_names.append(a, typeDefName((try wantList(field))));
            try type_forms.append(a, (try wantList(field)));
            try rec_sizes.append(a, 1);
        } else if (std.mem.eql(u8, kw, "rec")) {
            var n: u32 = 0;
            for ((try wantList(field))[1..]) |t| {
                if (std.mem.eql(u8, t.keyword() orelse continue, "type")) {
                    try type_names.append(a, typeDefName((try wantList(t))));
                    try type_forms.append(a, (try wantList(t)));
                    n += 1;
                }
            }
            try rec_sizes.append(a, n);
        }
    }
    // Pre-pass B: parse the bodies now that all type names resolve.
    for (type_forms.items) |form|
        try parseTypeBody(a, form, type_names.items, &sigs, &gc_types, &gc_field_names, &gc_supers, &gc_finals);

    // Pass 1: collect the remaining definitions. Imports (top-level or inline)
    // must precede every func/table/memory/global/tag definition (§6.6.13), so an
    // import after a definition is rejected rather than silently mis-indexed. Tags
    // are in `isDefKind` for this reason: an imported tag takes a low tag index, so
    // a defined tag before it would otherwise mis-align the source-order tag space.
    var seen_definition = false;
    for (module[start..]) |field| {
        const kw = field.keyword() orelse return error.BadModuleField;
        const items = (try wantList(field));
        if (fieldIsImport(kw, items)) {
            if (seen_definition) return error.ImportAfterDefinition;
        } else if (isDefKind(kw)) {
            seen_definition = true;
        }
        // Snapshot the per-kind import counts; whichever grew after this field is
        // processed is recorded in `import_order` (see its declaration).
        const imp_before = [5]usize{ func_imports.items.len, table_imports.items.len, mem_imports.items.len, global_imports.items.len, tag_imports.items.len };
        if (std.mem.eql(u8, kw, "func")) {
            const f = try parseFunc(a, items, type_names.items);
            const idx: u32 = @intCast(func_names.items.len); // func-space index (imports first)
            for (f.exports.items) |name| try exports.append(a, .{ .name = name, .kind = 0, .index = idx });
            if (f.import) |m| {
                try func_imports.append(a, .{ .module = m.module, .name = m.name, .type_ref = f.type_ref, .params = f.params.items, .results = f.results.items });
            } else {
                try funcs.append(a, f);
            }
            try func_names.append(a, f.name);
        } else if (std.mem.eql(u8, kw, "export")) {
            // (export "name" (func|table|memory|global|tag $id|N))
            //
            // Resolution is DEFERRED to after the field loop: a module-level
            // export may name something declared later in the file, and binaryen
            // emits exactly that order (all exports, then the funcs). Resolving
            // in-pass reported `UnknownIdentifier` for a perfectly good module.
            // Inline `(export …)` fields stay immediate — they can only refer to
            // the item they sit inside.
            try pending_exports.append(a, items);
        } else if (std.mem.eql(u8, kw, "global")) {
            try parseGlobal(a, items, &globals, &global_imports, &global_names, &exports, type_names.items);
        } else if (std.mem.eql(u8, kw, "tag")) {
            // (tag $name? (type $t) | (param …)*) — an exception tag names a type
            // index (params = the exception's value types; no results).
            var j: usize = 1;
            const nm = if (j < items.len and isId(items[j])) blk: {
                defer j += 1;
                break :blk items[j].asAtom();
            } else null;
            var type_ref: ?u32 = null;
            var params: List(V) = .empty;
            var results: List(V) = .empty;
            // An inline `(export "…")` used to fall through to the `else break`,
            // which terminated the loop — so the export was never emitted AND the
            // `(param …)` that followed it was never read, leaving the tag with an
            // empty `() -> ()` signature. Both losses were silent and the module
            // still validated: 15 of 666 corpus files (binaryen/TS output) lost
            // their `__exn_tag` export this way while reporting VALIDATE-OK.
            //
            // The tag's index is its position in the tag index space, which the
            // `tag_names` length gives (imported tags are appended there too).
            var tag_exports: List([]const u8) = .empty;
            var import_mn: ?struct { m: []const u8, n: []const u8 } = null;
            while (j < items.len) : (j += 1) {
                const tkw = items[j].keyword() orelse break;
                if (std.mem.eql(u8, tkw, "type")) {
                    type_ref = try resolveType(type_names.items, try nth(try wantList(items[j]), 1));
                } else if (std.mem.eql(u8, tkw, "param")) {
                    try parseDecls(a, (try wantList(items[j])), &params, null, type_names.items);
                } else if (std.mem.eql(u8, tkw, "result")) {
                    try parseDecls(a, (try wantList(items[j])), &results, null, type_names.items);
                } else if (std.mem.eql(u8, tkw, "export")) {
                    try tag_exports.append(a, try fieldStr(items[j], 1));
                } else if (std.mem.eql(u8, tkw, "import")) {
                    // (tag $id? (export …)* (import "m" "n") (param …)*) — an imported
                    // tag. Its params/type still follow and are parsed as usual.
                    const imp = try wantList(items[j]);
                    import_mn = .{ .m = try strAt(imp, 1), .n = try strAt(imp, 2) };
                } else break;
            }
            const tag_index: u32 = @intCast(tag_names.items.len);
            for (tag_exports.items) |en|
                try exports.append(a, .{ .name = en, .kind = 4, .index = tag_index });
            const tag_sig = try resolveTagSig(a, &sigs, type_ref, params.items, results.items);
            // An imported tag goes to the import section (low indices); a defined
            // one to the tag section. `tag_names` spans both for `$e` resolution.
            if (import_mn) |im| {
                try tag_imports.append(a, .{ .module = im.m, .name = im.n, .sig = tag_sig });
            } else {
                try tag_types.append(a, tag_sig);
            }
            try tag_names.append(a, nm);
        } else if (std.mem.eql(u8, kw, "memory")) {
            var mi: usize = 1;
            var this_name: ?[]const u8 = null;
            if (mi < items.len and isId(items[mi])) {
                this_name = items[mi].asAtom();
                mi += 1;
            }
            // Optional index type `i64` (memory64) / `i32`, right after the name.
            // `this_type_seen` blocks a SECOND index type in the canonical position
            // (`parseMemLimits`), so `(memory i64 i64 1)` is rejected, not doubled.
            var this_is64 = false;
            var this_type_seen = false;
            if (mi < items.len and eqAtom(items[mi], "i64")) {
                this_is64 = true;
                this_type_seen = true;
                mi += 1;
            } else if (mi < items.len and eqAtom(items[mi], "i32")) {
                this_type_seen = true;
                mi += 1;
            }
            // This memory's index in the index space (imports precede defs).
            const midx: u32 = @intCast(mem_names.items.len);
            while (mi < items.len and eqKw(items[mi], "export")) : (mi += 1)
                try exports.append(a, .{ .name = try fieldStr(items[mi], 1), .kind = 2, .index = midx });
            if (mi < items.len and eqKw(items[mi], "import")) {
                // (memory (export …)* (import "m" "n") min max? shared?)
                const imp = (try wantList(items[mi]));
                mi += 1;
                const lim = try parseMemLimits(items, &mi, this_is64, this_type_seen);
                try checkMemTail(items, mi);
                try mem_imports.append(a, .{ .module = (try strAt(imp, 1)), .name = (try strAt(imp, 2)), .min = lim.min, .max = lim.max, .shared = lim.shared, .is64 = lim.is64 });
            } else if (mi < items.len and eqKw(items[mi], "data")) {
                // (memory (data "…")) — size the memory to the bytes and append an
                // active data segment at offset 0 targeting THIS memory.
                var bytes: List(u8) = .empty;
                for ((try wantList(items[mi]))[1..]) |it| switch (it) {
                    .string => |sbytes| try bytes.appendSlice(a, sbytes),
                    else => {},
                };
                const pages: u64 = @intCast((bytes.items.len + 65535) / 65536);
                try memories.append(a, .{ .min = pages, .max = pages, .is64 = this_is64 });
                const off = try a.alloc(Sexpr, 2);
                // The active-data offset takes the memory's index type.
                off[0] = .{ .atom = if (this_is64) "i64.const" else "i32.const" };
                off[1] = .{ .atom = "0" };
                // Keep `data_names` index-aligned with `datas`: this inline
                // `(memory (data …))` form has no `$id` of its own.
                try data_names.append(a, null);
                try datas.append(a, .{ .mem_index = midx, .offset_form = .{ .list = off }, .bytes = bytes.items });
            } else {
                // (memory $m? i64? (export …)* i64? min max? shared?) — the index
                // type may sit here (canonical) or right after the name; `shared`
                // (threads) follows the limits and requires a max.
                const lim = try parseMemLimits(items, &mi, this_is64, this_type_seen);
                try checkMemTail(items, mi);
                try memories.append(a, .{ .min = lim.min, .max = lim.max, .shared = lim.shared, .is64 = lim.is64 });
            }
            try mem_names.append(a, this_name);
        } else if (std.mem.eql(u8, kw, "data")) {
            // (data $id? (memory idx)? offset-expr? "bytes"…) — active when an
            // offset is present, else passive. A `(memory idx)` prefix targets a
            // specific memory (multi-memory).
            var di: usize = 1;
            var dname: ?[]const u8 = null;
            if (di < items.len and isId(items[di])) {
                dname = items[di].asAtom();
                di += 1; // $id
            }
            try data_names.append(a, dname);
            var seg_mem: u32 = 0;
            if (di < items.len) if (items[di].asList()) |l| {
                if (l.len >= 2 and eqAtom(l[0], "memory")) {
                    seg_mem = try resolveByName(mem_names.items, l[1]);
                    di += 1;
                }
            };
            // The offset is any leading list (`(offset …)` or a folded const-expr
            // like `(i32.const N)` / `(global.get $g)` — even a malformed one, so
            // the validator can reject it); data bytes are always strings. Absent
            // → passive.
            var offset_form: ?Sexpr = null;
            if (di < items.len and items[di].asList() != null) {
                offset_form = items[di];
                di += 1;
            }
            var bytes: List(u8) = .empty;
            for (items[di..]) |it| switch (it) {
                .string => |sbytes| try bytes.appendSlice(a, sbytes),
                else => {},
            };
            try datas.append(a, .{ .mem_index = seg_mem, .offset_form = offset_form, .bytes = bytes.items });
        } else if (std.mem.eql(u8, kw, "table")) {
            // Inline import `(table $id? (export …)* (import "m" "n") min max? reftype)`
            // is handled here; a defined table goes to `parseTable`.
            var ti: usize = 1;
            var tname: ?[]const u8 = null;
            if (ti < items.len and isId(items[ti])) {
                tname = items[ti].atom;
                ti += 1;
            }
            const exp_start = ti;
            while (ti < items.len and eqKw(items[ti], "export")) ti += 1;
            if (ti < items.len and eqKw(items[ti], "import")) {
                const imp = (try wantList(items[ti]));
                const tidx: u32 = @intCast(table_names.items.len);
                for (items[exp_start..ti]) |ex|
                    try exports.append(a, .{ .name = try fieldStr(ex, 1), .kind = 1, .index = tidx });
                ti += 1;
                const tmin = try parseIndex(try nth(items, ti));
                ti += 1;
                var tmax: ?u32 = null;
                if (ti < items.len and !isRefType(items[ti])) {
                    tmax = try parseIndex(items[ti]);
                    ti += 1;
                }
                try table_imports.append(a, .{ .module = (try strAt(imp, 1)), .name = (try strAt(imp, 2)), .min = tmin, .max = tmax, .elem = try parseValType(try nth(items, ti), type_names.items) });
                try table_names.append(a, tname);
            } else {
                try parseTable(a, items, &tables, &table_names, &elems, &elem_names, &exports, type_names.items);
            }
        } else if (std.mem.eql(u8, kw, "elem")) {
            try parseElem(a, items, &elems, &elem_names, table_names.items, type_names.items);
        } else if (std.mem.eql(u8, kw, "import")) {
            // (import "m" "n" (func …) | (global …)) — func + global imports.
            const desc = try wantList(try nth(items, 3));
            const dkw = try wantAtom(try nth(desc, 0));
            if (std.mem.eql(u8, dkw, "func")) {
                const f = try parseFunc(a, desc, type_names.items); // reuse: parses $id + typeuse
                try func_imports.append(a, .{ .module = (try strAt(items, 1)), .name = (try strAt(items, 2)), .type_ref = f.type_ref, .params = f.params.items, .results = f.results.items });
                try func_names.append(a, f.name);
            } else if (std.mem.eql(u8, dkw, "table")) {
                // (import "m" "n" (table $id? min max? reftype)) — imported tables
                // take the low table indices (before any defined table).
                var ti: usize = 1;
                var tname: ?[]const u8 = null;
                if (ti < desc.len and isId(desc[ti])) {
                    tname = desc[ti].atom;
                    ti += 1;
                }
                const tmin = try parseIndex(try nth(desc, ti));
                ti += 1;
                var tmax: ?u32 = null;
                if (ti < desc.len and !isRefType(desc[ti])) {
                    tmax = try parseIndex(desc[ti]);
                    ti += 1;
                }
                try table_imports.append(a, .{ .module = (try strAt(items, 1)), .name = (try strAt(items, 2)), .min = tmin, .max = tmax, .elem = try parseValType(try nth(desc, ti), type_names.items) });
                try table_names.append(a, tname);
            } else if (std.mem.eql(u8, dkw, "memory")) {
                // (import "m" "n" (memory $id? i64? min max? shared?))
                var mi2: usize = 1;
                var mname: ?[]const u8 = null;
                if (mi2 < desc.len and isId(desc[mi2])) {
                    mname = desc[mi2].atom;
                    mi2 += 1;
                }
                const lim = try parseMemLimits(desc, &mi2, false, false);
                try mem_imports.append(a, .{ .module = (try strAt(items, 1)), .name = (try strAt(items, 2)), .min = lim.min, .max = lim.max, .shared = lim.shared, .is64 = lim.is64 });
                try mem_names.append(a, mname);
            } else if (std.mem.eql(u8, dkw, "tag")) {
                // (import "m" "n" (tag $id? (type $t) | (param …)*)) — imported tags
                // take the low tag indices (before any defined tag).
                var gi: usize = 1;
                var gname: ?[]const u8 = null;
                if (gi < desc.len and isId(desc[gi])) {
                    gname = desc[gi].atom;
                    gi += 1;
                }
                const sig = try parseTagType(a, desc, gi, &sigs, type_names.items);
                try tag_imports.append(a, .{ .module = (try strAt(items, 1)), .name = (try strAt(items, 2)), .sig = sig });
                try tag_names.append(a, gname);
            } else {
                try parseImport(a, items, &global_imports, &global_names, type_names.items); // global
            }
        } else if (std.mem.eql(u8, kw, "start")) {
            // (start $f | N) — resolve after the func index space is complete.
            if (items.len < 2) return error.BadModuleField;
            start_ref = items[1];
        } else if (!std.mem.eql(u8, kw, "type") and !std.mem.eql(u8, kw, "rec")) {
            // Anything else is a typo or an unsupported field, and silently
            // dropping it assembled a module MISSING what the source asked for:
            // `(exprot "g" (func 0))` vanished and the export simply didn't
            // exist. Emitting a module that doesn't match its source is the
            // canonical failure this project's audit protocol names.
            // (`type`/`rec` are handled by the pre-pass above.)
            return error.BadModuleField;
        }
        // Record which import kind (if any) this field added, in source order.
        if (func_imports.items.len > imp_before[0]) try import_order.append(a, .func);
        if (table_imports.items.len > imp_before[1]) try import_order.append(a, .table);
        if (mem_imports.items.len > imp_before[2]) try import_order.append(a, .mem);
        if (global_imports.items.len > imp_before[3]) try import_order.append(a, .global);
        if (tag_imports.items.len > imp_before[4]) try import_order.append(a, .tag);
    }

    // Module-level exports, resolved now that every index space is complete.
    // Doing this in-pass rejected forward references — and binaryen emits all
    // the exports BEFORE the functions they name, so most real optimizer output
    // hit it.
    for (pending_exports.items) |items| {
        const name = (try strAt(items, 1));
        const target = (try wantList(try nth(items, 2)));
        const tkw = (try wantAtom(try nth(target, 0)));
        const kind: u8 = if (std.mem.eql(u8, tkw, "func")) 0 else if (std.mem.eql(u8, tkw, "table")) 1 else if (std.mem.eql(u8, tkw, "memory")) 2 else if (std.mem.eql(u8, tkw, "global")) 3 else if (std.mem.eql(u8, tkw, "tag")) 4 else return error.BadModuleField;
        const idx: u32 = switch (kind) {
            0 => try resolveByName(func_names.items, try nth(target, 1)),
            1 => try resolveByName(table_names.items, try nth(target, 1)),
            2 => try resolveByName(mem_names.items, try nth(target, 1)),
            3 => try resolveByName(global_names.items, try nth(target, 1)),
            4 => try resolveByName(tag_names.items, try nth(target, 1)),
            else => unreachable,
        };
        try exports.append(a, .{ .name = name, .kind = kind, .index = idx });
    }

    // Function type indices (`(type $t)` reference, else intern the inline sig),
    // then pre-encode bodies (which may intern block-type sigs / resolve
    // call_indirect type refs), so the type section is complete before emit.
    // Imported-function type indices (for the import section).
    var func_import_type: List(u32) = .empty;
    for (func_imports.items) |fi| {
        const ti = if (fi.type_ref) |tr| try resolveType(type_names.items, tr) else try internSig(a, &sigs, fi.params, fi.results);
        try func_import_type.append(a, ti);
    }

    var func_type: List(u32) = .empty;
    for (funcs.items) |*f| {
        const ti = if (f.type_ref) |tr| try resolveType(type_names.items, tr) else try internSig(a, &sigs, f.params.items, f.results.items);
        try func_type.append(a, ti);
        // A `(type $t)` reference supplies the params; when they aren't *also*
        // written inline, they still occupy the low local indices, so prepend
        // anonymous names to keep declared-local indices correct.
        if (f.type_ref != null and f.params.items.len == 0 and ti < sigs.items.len) {
            const params = sigs.items[ti].params;
            if (params.len != 0) {
                var names: List(?[]const u8) = .empty;
                for (params) |_| try names.append(a, null);
                try names.appendSlice(a, f.local_names.items);
                f.local_names = names;
            }
        }
    }

    var bodies: List([]const u8) = .empty;
    for (funcs.items) |f| try bodies.append(a, try encodeBody(a, f, func_names.items, &sigs, type_names.items, global_names.items, table_names.items, elem_names.items, tag_names.items, data_names.items, mem_names.items, gc_field_names.items));

    // Pre-encode every const-expr-bearing section (global inits, element and data
    // exprs/offsets) BEFORE the type section, mirroring the function-body path, so
    // any signature they might intern lands in section 1. Const-exprs can't intern
    // a signature today, but this keeps the invariant structural, not incidental.
    const global_pay = try encodeGlobalSection(a, globals.items, &sigs, type_names.items, global_names.items, func_names.items);
    const elem_pay = try encodeElementSection(a, elems.items, &sigs, type_names.items, global_names.items, func_names.items);
    const data_pay = try encodeDataSection(a, datas.items, &sigs, type_names.items, global_names.items, func_names.items);

    var out: List(u8) = .empty;
    try out.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }); // header

    // Type section (1) — func sigs (named + interned block-type sigs) plus GC
    // struct/array composite types. `gc_types` covers the leading named defs;
    // any index beyond it is an interned func signature.
    {
        var s: List(u8) = .empty;
        // The section counts REC-TYPE entries, and a `(rec …)` of n members is
        // ONE entry. Interned block-type signatures sit past the named defs and
        // are each their own entry.
        const named = gc_types.items.len;
        var entries: usize = sigs.items.len - named;
        for (rec_sizes.items) |n| entries += if (n == 0) 0 else 1;
        try uleb(a, &s, entries);
        // Walks `rec_sizes` alongside the type indices so a group header can be
        // emitted before its first member.
        var group: usize = 0;
        var group_left: u32 = 0;
        for (sigs.items, 0..) |sig, ti| {
            if (ti < named and group_left == 0) {
                while (group < rec_sizes.items.len and rec_sizes.items[group] == 0) group += 1;
                if (group < rec_sizes.items.len) {
                    group_left = rec_sizes.items[group];
                    group += 1;
                    // A bare subtype IS a singleton group, so only n > 1 needs the
                    // explicit `0x4e` header.
                    if (group_left > 1) {
                        try s.append(a, 0x4e);
                        try uleb(a, &s, group_left);
                    }
                } else group_left = 1;
            }
            if (group_left > 0) group_left -= 1;
            const def: GcTypeDef = if (ti < gc_types.items.len) gc_types.items[ti] else .func;
            // Emit the sub form whenever the source said `sub` — even with no
            // supertype, because that is what makes the type EXTENSIBLE (`0x50`
            // = non-final, `0x4f` = final). A bare composite type is `sub final`
            // by definition, so only a `final`-with-supertype declaration needs
            // the explicit `0x4f`.
            const is_final = ti >= gc_finals.items.len or gc_finals.items[ti];
            const super: ?Sexpr = if (ti < gc_supers.items.len) gc_supers.items[ti] else null;
            if (!is_final or super != null) {
                try s.append(a, if (is_final) 0x4f else 0x50);
                if (super) |sr| {
                    try uleb(a, &s, 1);
                    try uleb(a, &s, try resolveType(type_names.items, sr));
                } else try uleb(a, &s, 0);
            }
            switch (def) {
                .func => {
                    try s.append(a, 0x60);
                    try valTypeVec(a, &s, sig.params);
                    try valTypeVec(a, &s, sig.results);
                },
                .@"struct" => |fs| {
                    try s.append(a, 0x5f);
                    try uleb(a, &s, fs.len);
                    for (fs) |f| try emitGcField(a, &s, f);
                },
                .array => |f| {
                    try s.append(a, 0x5e);
                    try emitGcField(a, &s, f);
                },
            }
        }
        try emitSection(a, &out, 1, s.items);
    }
    // Import section (2) — imported functions, tables, memories, globals.
    const n_imports = func_imports.items.len + table_imports.items.len + mem_imports.items.len + global_imports.items.len + tag_imports.items.len;
    if (n_imports != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, n_imports);
        // Emit in SOURCE order (from `import_order`), not grouped by kind. Each
        // kind advances its own cursor, so the per-kind lists — which already
        // hold entries in source order and drive the index spaces — line up.
        var ci = [5]usize{ 0, 0, 0, 0, 0 };
        for (import_order.items) |tag| switch (tag) {
            .func => {
                const fi = func_imports.items[ci[0]];
                try nameBytes(a, &s, fi.module);
                try nameBytes(a, &s, fi.name);
                try s.append(a, 0x00); // func import
                try uleb(a, &s, func_import_type.items[ci[0]]); // type index
                ci[0] += 1;
            },
            .table => {
                const t = table_imports.items[ci[1]];
                try nameBytes(a, &s, t.module);
                try nameBytes(a, &s, t.name);
                try s.append(a, 0x01); // table import
                try emitValType(a, &s, t.elem); // element reftype
                try emitLimits(a, &s, t.min, if (t.max) |mx| @as(u64, mx) else null, false, false);
                ci[1] += 1;
            },
            .mem => {
                const m = mem_imports.items[ci[2]];
                try nameBytes(a, &s, m.module);
                try nameBytes(a, &s, m.name);
                try s.append(a, 0x02); // memory import
                try emitLimits(a, &s, m.min, m.max, m.shared, m.is64);
                ci[2] += 1;
            },
            .global => {
                const g = global_imports.items[ci[3]];
                try nameBytes(a, &s, g.module);
                try nameBytes(a, &s, g.name);
                try s.append(a, 0x03); // global import
                try emitValType(a, &s, g.valtype);
                try s.append(a, if (g.mutable) 0x01 else 0x00);
                ci[3] += 1;
            },
            .tag => {
                const t = tag_imports.items[ci[4]];
                try nameBytes(a, &s, t.module);
                try nameBytes(a, &s, t.name);
                try s.append(a, 0x04); // tag import
                try s.append(a, 0x00); // attribute: exception
                try uleb(a, &s, t.sig); // type (signature) index
                ci[4] += 1;
            },
        };
        try emitSection(a, &out, 2, s.items);
    }
    // Function section (3)
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, func_type.items.len);
        for (func_type.items) |ti| try uleb(a, &s, ti);
        try emitSection(a, &out, 3, s.items);
    }
    // Table section (4)
    if (tables.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, tables.items.len);
        for (tables.items) |t| {
            try emitValType(a, &s, t.elem); // element reftype (funcref / externref)
            try emitLimits(a, &s, t.min, if (t.max) |mx| @as(u64, mx) else null, false, false);
        }
        try emitSection(a, &out, 4, s.items);
    }
    // Memory section (5) — the *defined* memories only (imported ones live in
    // the import section). Multi-memory: a vector of limits.
    if (memories.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, memories.items.len);
        for (memories.items) |m| try emitLimits(a, &s, m.min, m.max, m.shared, m.is64);
        try emitSection(a, &out, 5, s.items);
    }
    // Tag section (13) — exception tags. Ordered after memory (5) and before
    // global (6), per the EH proposal's section order.
    if (tag_types.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, tag_types.items.len);
        for (tag_types.items) |ti| {
            try s.append(a, 0x00); // attribute: exception
            try uleb(a, &s, ti);
        }
        try emitSection(a, &out, 13, s.items);
    }
    // Global section (6) — pre-encoded above (before the type section).
    if (globals.items.len != 0) try emitSection(a, &out, 6, global_pay);
    // Export section (7)
    if (exports.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, exports.items.len);
        for (exports.items) |e| {
            try nameBytes(a, &s, e.name);
            try s.append(a, e.kind);
            try uleb(a, &s, e.index);
        }
        try emitSection(a, &out, 7, s.items);
    }
    // Start section (8) — the funcidx to run at instantiation.
    if (start_ref) |ref| {
        var s: List(u8) = .empty;
        try uleb(a, &s, try resolveByName(func_names.items, ref));
        try emitSection(a, &out, 8, s.items);
    }
    // Element section (9) — pre-encoded above (before the type section).
    if (elems.items.len != 0) try emitSection(a, &out, 9, elem_pay);
    // Data-count section (12) — the segment count, ahead of the code that uses
    // it. §5.5.16 REQUIRES it in any module whose code has `memory.init`/
    // `data.drop`, and we emitted it never: every `(data …)` module this
    // assembler produced was malformed the moment a body touched a segment.
    // Nothing caught it because the decoder did not enforce the rule either —
    // the two halves of the same gap agreed with each other. Emitting it
    // whenever there IS a data section is simplest and always legal: when no
    // instruction needs it the section is merely optional, and `decode` checks
    // the count against `data.len` either way.
    if (datas.items.len != 0) {
        var s: List(u8) = .empty;
        try uleb(a, &s, datas.items.len);
        try emitSection(a, &out, 12, s.items);
    }
    // Code section (10) — pre-encoded bodies
    {
        var s: List(u8) = .empty;
        try uleb(a, &s, bodies.items.len);
        for (bodies.items) |body| {
            try uleb(a, &s, body.len);
            try s.appendSlice(a, body);
        }
        try emitSection(a, &out, 10, s.items);
    }
    // Data section (11) — pre-encoded above (before the type section).
    if (datas.items.len != 0) try emitSection(a, &out, 11, data_pay);

    return out.items;
}

/// Encode the global section (6) payload: `(valtype, mut, init-const-expr)` per
/// global. Const-exprs are encoded here (pre-type-section) so any interning lands
/// in section 1.
fn encodeGlobalSection(a: std.mem.Allocator, globals: []const GlobalDef, sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8) Error![]const u8 {
    if (globals.len == 0) return &.{};
    var s: List(u8) = .empty;
    try uleb(a, &s, globals.len);
    for (globals) |g| {
        try emitValType(a, &s, g.valtype);
        try s.append(a, if (g.mutable) 0x01 else 0x00);
        try emitConstExpr(a, &s, sigs, type_names, global_names, func_names, g.init);
    }
    return s.items;
}

/// Encode the element section (9) payload — all 8 flag variants
/// (active/passive/declarative × func-index/const-expr forms).
fn encodeElementSection(a: std.mem.Allocator, elems: []const ElemDef, sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8) Error![]const u8 {
    if (elems.len == 0) return &.{};
    var s: List(u8) = .empty;
    try uleb(a, &s, elems.len);
    for (elems) |e| {
        // flag bits: bit0 = passive/declarative, bit1 = declarative-or-explicit-table,
        // bit2 = const-expr form.
        const explicit_table = e.mode == .active and e.table_index != 0;
        var flag: u8 = 0;
        switch (e.mode) {
            .active => flag |= if (explicit_table) 0b010 else 0,
            .passive => flag |= 0b001,
            .declarative => flag |= 0b011,
        }
        if (e.expr_form) flag |= 0b100;
        try s.append(a, flag);
        if (explicit_table) try uleb(a, &s, e.table_index);
        if (e.mode == .active) try emitOffsetExpr(a, &s, sigs, type_names, global_names, func_names, e.offset_form);
        // The leading kind byte: elemkind (0x00) for non-flag-0 func-index
        // variants, reftype for non-flag-4 const-expr variants.
        if (!e.expr_form and flag != 0) {
            try s.append(a, 0x00); // elemkind funcref
        } else if (e.expr_form and flag != 4) {
            try emitValType(a, &s, e.elem_type); // reftype
        }
        if (e.expr_form) {
            try uleb(a, &s, e.exprs.len);
            for (e.exprs) |ex| try emitElementExpr(a, &s, sigs, type_names, global_names, func_names, ex);
        } else {
            try uleb(a, &s, e.funcs.len);
            for (e.funcs) |ref| try uleb(a, &s, try resolveByName(func_names, ref));
        }
    }
    return s.items;
}

/// Encode the data section (11) payload: active (flag 0x00, offset const-expr) or
/// passive (flag 0x01) segments, memory 0.
fn encodeDataSection(a: std.mem.Allocator, datas: []const DataSeg, sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8) Error![]const u8 {
    if (datas.len == 0) return &.{};
    var s: List(u8) = .empty;
    try uleb(a, &s, datas.len);
    for (datas) |seg| {
        if (seg.offset_form == null) {
            try s.append(a, 0x01); // passive
        } else if (seg.mem_index == 0) {
            try s.append(a, 0x00); // active, memory 0
            try emitOffsetExpr(a, &s, sigs, type_names, global_names, func_names, seg.offset_form);
        } else {
            // active, explicit memory index (multi-memory)
            try s.append(a, 0x02);
            try uleb(a, &s, seg.mem_index);
            try emitOffsetExpr(a, &s, sigs, type_names, global_names, func_names, seg.offset_form);
        }
        try uleb(a, &s, seg.bytes.len);
        try s.appendSlice(a, seg.bytes);
    }
    return s.items;
}

// --- Module-field parsing --------------------------------------------------

/// A module field that defines an index-space entry (func/table/memory/global).
fn isDefKind(kw: []const u8) bool {
    return std.mem.eql(u8, kw, "func") or std.mem.eql(u8, kw, "table") or
        std.mem.eql(u8, kw, "memory") or std.mem.eql(u8, kw, "global") or
        std.mem.eql(u8, kw, "tag");
}

/// True if `field` is an import: a top-level `(import …)` or a def-kind field with
/// an inline `(import "m" "n")` (allowed only among the leading `$id`/`(export …)`
/// forms, before the type/limits/body).
fn fieldIsImport(kw: []const u8, items: []const Sexpr) bool {
    if (std.mem.eql(u8, kw, "import")) return true;
    if (!isDefKind(kw)) return false;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        if (items[i].asAtom() != null) continue; // $id
        const l = items[i].asList() orelse return false;
        if (l.len == 0) return false;
        const h = l[0].asAtom() orelse return false;
        if (std.mem.eql(u8, h, "import")) return true;
        if (std.mem.eql(u8, h, "export")) continue;
        return false; // reached the type/limits/body — no inline import
    }
    return false;
}

/// The `$name` of a `(type $name? …)` definition, or null.
fn typeDefName(items: []const Sexpr) ?[]const u8 {
    return if (items.len >= 2 and isId(items[1])) items[1].atom else null;
}

/// Parse a `(type $name? <comptype>)` body (`(func …)`/`(struct …)`/`(array …)`,
/// optionally `(sub final? $super? <comptype>)`). Appends the func signature (to
/// `sigs`) or the struct/array fields (to `gc_types`) plus the declared supertype
/// (to `gc_supers`, resolved at emit) at the next type index — all index-aligned
/// with `type_names` (already fully populated, so concrete `(ref $t)` resolves).
fn parseTypeBody(a: std.mem.Allocator, items: []const Sexpr, type_names: []const ?[]const u8, sigs: *List(Sig), gc_types: *List(GcTypeDef), gc_field_names: *List([]const ?[]const u8), gc_supers: *List(?Sexpr), gc_finals: *List(bool)) Error!void {
    var i: usize = 1;
    if (i < items.len and isId(items[i])) i += 1; // skip $name (already collected)
    var body = try wantList(try nth(items, i));
    // Unwrap a `(sub final? $super? <comptype>)`: the inner comptype is the last
    // element; a supertype id among the middle elements (skipping `final`) is
    // captured so the type section can emit the sub form (GC MVP: ≤1 supertype).
    //
    // ⚠️ FINALITY IS PART OF THE TYPE, not decoration. `(sub …)` without `final`
    // opens the type for extension; a bare `(func …)` / `(struct …)` / `(array
    // …)` is final. We recorded only the supertype, so `(type $e0 (sub (array
    // i32)))` — `sub`, no supertype — emitted a BARE composite and came back
    // final, and every later `(sub $e0 …)` then extended a closed type.
    var super_ref: ?Sexpr = null;
    var final = true;
    if (body.len >= 2 and eqAtom(body[0], "sub")) {
        final = false;
        for (body[1 .. body.len - 1]) |part| {
            if (eqAtom(part, "final")) {
                final = true;
                continue;
            }
            if (super_ref == null and (isId(part) or part.asAtom() != null)) super_ref = part;
        }
        body = body[body.len - 1].asList() orelse return error.BadModuleField;
    }
    try gc_supers.append(a, super_ref);
    try gc_finals.append(a, final);

    const kw = try wantAtom(try nth(body, 0));
    if (std.mem.eql(u8, kw, "func")) {
        var params: List(V) = .empty;
        var results: List(V) = .empty;
        for (body[1..]) |part| {
            // An unrecognised part used to be skipped, so
            // `(type $t (func (parm i32) (reslt i32)))` interned `() -> ()` and a
            // `call_indirect` against `$t` then checked the WRONG signature.
            const pk = part.keyword() orelse return error.BadModuleField;
            if (std.mem.eql(u8, pk, "param")) {
                try parseDecls(a, (try wantList(part)), &params, null, type_names);
            } else if (std.mem.eql(u8, pk, "result")) {
                try parseDecls(a, (try wantList(part)), &results, null, type_names);
            } else return error.BadModuleField;
        }
        try sigs.append(a, .{ .params = params.items, .results = results.items });
        try gc_types.append(a, .func);
        try gc_field_names.append(a, &.{}); // func types have no named fields
    } else if (std.mem.eql(u8, kw, "struct")) {
        var fields: List(GcField) = .empty;
        var names: List(?[]const u8) = .empty;
        for (body[1..]) |part| {
            // Same rule as the `func` arm above: a mistyped part must not be
            // silently dropped, or the struct is assembled with missing fields.
            if (!std.mem.eql(u8, part.keyword() orelse return error.BadModuleField, "field"))
                return error.BadModuleField;
            try parseFieldGroup(a, (try wantList(part)), &fields, &names, type_names);
        }
        try sigs.append(a, .{ .params = &.{}, .results = &.{}, .gc_placeholder = true });
        try gc_types.append(a, .{ .@"struct" = fields.items });
        try gc_field_names.append(a, names.items); // index-aligned with `fields`
    } else if (std.mem.eql(u8, kw, "array")) {
        if (body.len < 2) return error.BadModuleField;
        // `(array <fieldtype>)` — exactly one element field. The element may be a
        // `(field <ft>)` wrapper or a bare field type (`i32` / `(mut …)` / `i8`).
        const is_field_form = std.mem.eql(u8, body[1].keyword() orelse "", "field");
        const elem: GcField = if (is_field_form) blk: {
            var fields: List(GcField) = .empty;
            var names: List(?[]const u8) = .empty;
            try parseFieldGroup(a, (try wantList(body[1])), &fields, &names, type_names);
            if (fields.items.len != 1) return error.BadModuleField;
            break :blk fields.items[0];
        } else try parseFieldElem(body[1], type_names);
        try sigs.append(a, .{ .params = &.{}, .results = &.{}, .gc_placeholder = true });
        try gc_types.append(a, .{ .array = elem });
        try gc_field_names.append(a, &.{}); // array elements are accessed by index, not name
    } else return error.BadModuleField;
}

/// Parse a `(field …)` group: an optional `$id` then one-or-more field types
/// (`(field $x i32)` / `(field i32 (mut i64))`), appending each to `out`.
fn parseFieldGroup(a: std.mem.Allocator, list: []const Sexpr, out: *List(GcField), names_out: *List(?[]const u8), type_names: []const ?[]const u8) Error!void {
    var i: usize = 1;
    // `(field $id ft)` names exactly one field; `(field ft1 ft2 …)` is a group of
    // anonymous fields. Keep `names_out` index-aligned with `out`.
    var name: ?[]const u8 = null;
    if (i < list.len and isId(list[i])) {
        name = list[i].asAtom();
        i += 1;
    }
    while (i < list.len) : (i += 1) {
        try out.append(a, try parseFieldElem(list[i], type_names));
        try names_out.append(a, name); // only the (single) named field carries a name
    }
}

/// Parse one field type: `(mut <storage>)` or a bare `<storage>`, where storage
/// is `i8` / `i16` (packed) or a value type.
fn parseFieldElem(s: Sexpr, type_names: []const ?[]const u8) Error!GcField {
    if (s.asList()) |l| {
        if (l.len == 2 and eqAtom(l[0], "mut")) return .{ .storage = try parseStorage(l[1], type_names), .mutable = true };
    }
    return .{ .storage = try parseStorage(s, type_names), .mutable = false };
}

fn parseStorage(s: Sexpr, type_names: []const ?[]const u8) Error!GcStorage {
    if (s.asAtom()) |atom| {
        if (std.mem.eql(u8, atom, "i8")) return .i8;
        if (std.mem.eql(u8, atom, "i16")) return .i16;
    }
    return .{ .val = try parseValType(s, type_names) };
}

/// `(table $name? reftype (elem …))` or `(table $name? <min> <max>? reftype)`,
/// where reftype is `funcref` / `externref` / `(ref null? …)`.
fn parseTable(a: std.mem.Allocator, items: []const Sexpr, tables: *List(TableDef), table_names: *List(?[]const u8), elems: *List(ElemDef), elem_names: *List(?[]const u8), exports: *List(ExportDef), type_names: []const ?[]const u8) Error!void {
    const table_index: u32 = @intCast(tables.items.len);
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1;
    }
    // Inline exports: `(table $id? (export "x")* …)`.
    while (i < items.len and eqKw(items[i], "export")) : (i += 1)
        try exports.append(a, .{ .name = try fieldStr(items[i], 1), .kind = 1, .index = table_index });
    try table_names.append(a, name);
    // `(table)`, `(table $t)`, `(table (export "x"))` all leave `i == items.len`
    // here — the sibling of the guards `parseGlobal`/`parseElem`/the inline-import
    // branch already got. Unguarded this reads an adjacent `Sexpr` and switches on
    // a garbage union tag (UB in the shipped ReleaseFast build).
    const shape = try nth(items, i);
    if (isRefType(shape)) {
        // (table reftype (elem …))
        const et = try parseValType(shape, type_names);
        i += 1;
        if (i < items.len and eqKw(items[i], "elem")) {
            // Inline active elem at offset 0. Items are either bare func indices
            // (`(elem $f $g)`) or const-expr forms (`(elem (ref.func $f) …)`).
            const inner = (try wantList(items[i]))[1..];
            const count: u32 = @intCast(inner.len);
            try tables.append(a, .{ .min = count, .max = count, .elem = et });
            if (inner.len != 0 and inner[0].asList() != null) {
                try elems.append(a, .{ .mode = .active, .table_index = table_index, .offset_form = null, .elem_type = et, .expr_form = true, .funcs = &.{}, .exprs = inner });
            } else {
                try elems.append(a, .{ .mode = .active, .table_index = table_index, .offset_form = null, .elem_type = .funcref, .expr_form = false, .funcs = inner, .exprs = &.{} });
            }
            try elem_names.append(a, null);
        } else {
            try tables.append(a, .{ .min = 0, .max = null, .elem = et });
        }
    } else {
        const min = try parseIndex(shape);
        i += 1;
        var max: ?u32 = null;
        if (i < items.len and !isRefType(items[i])) {
            max = try parseIndex(items[i]);
            i += 1;
        }
        // `(table 1)` / `(table 1 2)` run out of items here — the twin-index
        // pattern: the `max` probe above is guarded, this read was not.
        const et = try parseValType(try nth(items, i), type_names);
        i += 1;
        try tables.append(a, .{ .min = min, .max = max, .elem = et });
        // Table initializer expression `(table N reftype initexpr)`: fill all N
        // slots with the value. We synthesize an active elem of N copies at
        // offset 0 — observably identical table state (a distinct 0x40 binary
        // encoding is not required for the execution assertions).
        if (i < items.len and items[i].asList() != null) {
            const init_expr = items[i];
            // `min` is attacker-written text: `(table 4000000000 funcref (…))` —
            // 48 bytes — asks for ~96 GB of `Sexpr`. `alloc` overflow-checks the
            // multiply so it fails cleanly rather than corrupting, but it is the
            // text-side twin of the OOM amplification `Reader.readVecLen` closed
            // on the binary side, so bound it the same way.
            if (min > max_table_init_copies) return error.BadImmediate;
            const copies = try a.alloc(Sexpr, min);
            for (copies) |*c| c.* = init_expr;
            try elems.append(a, .{ .mode = .active, .table_index = table_index, .offset_form = null, .elem_type = et, .expr_form = true, .funcs = &.{}, .exprs = copies });
            try elem_names.append(a, null);
        }
    }
}

/// True if the form is a reference type: `funcref` / `externref` / `(ref …)`.
fn isRefType(s: Sexpr) bool {
    if (s.asList()) |l| return l.len >= 1 and eqAtom(l[0], "ref");
    // `anyfunc` is the pre-standard spelling of `funcref`.
    return eqAtom(s, "funcref") or eqAtom(s, "externref") or eqAtom(s, "anyfunc");
}

/// `(elem $id? mode? tableuse? offset? kind item*)` — active / passive /
/// declarative, in either the func-index (`func $f …`) or const-expr
/// (`funcref (ref.func $f) …`) form.
fn parseElem(a: std.mem.Allocator, items: []const Sexpr, elems: *List(ElemDef), elem_names: *List(?[]const u8), table_names: []const ?[]const u8, type_names: []const ?[]const u8) Error!void {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1; // segment $id
    }
    try elem_names.append(a, name);
    var mode: @FieldType(ElemDef, "mode") = .passive;
    var table_index: u32 = 0;
    var offset_form: ?Sexpr = null;
    if (i < items.len and eqAtom(items[i], "declare")) {
        mode = .declarative;
        i += 1;
    } else {
        if (i < items.len and eqKw(items[i], "table")) {
            mode = .active;
            table_index = try resolveByName(table_names, try nth(try wantList(items[i]), 1));
            i += 1;
        }
        if (i < items.len and isOffsetForm(items[i])) {
            mode = .active;
            offset_form = items[i];
            i += 1;
        }
    }
    // Kind: `func` (func-index form) or a reference type (const-expr form). An
    // absent kind keyword is the abbreviated func-index form.
    if (i < items.len and eqAtom(items[i], "func")) {
        try elems.append(a, .{ .mode = mode, .table_index = table_index, .offset_form = offset_form, .elem_type = .funcref, .expr_form = false, .funcs = items[i + 1 ..], .exprs = &.{} });
    } else if (i < items.len and isRefType(items[i])) {
        const et = try parseValType(items[i], type_names);
        try elems.append(a, .{ .mode = mode, .table_index = table_index, .offset_form = offset_form, .elem_type = et, .expr_form = true, .funcs = &.{}, .exprs = items[i + 1 ..] });
    } else {
        try elems.append(a, .{ .mode = mode, .table_index = table_index, .offset_form = offset_form, .elem_type = .funcref, .expr_form = false, .funcs = items[i..], .exprs = &.{} });
    }
}

/// True if the form is an element-segment offset (`(offset …)` or a folded
/// const-expr like `(i32.const N)` / `(global.get $g)`) — distinct from a
/// `(ref …)` reftype and from a `(ref.func …)` element expression.
fn isOffsetForm(s: Sexpr) bool {
    const l = s.asList() orelse return false;
    if (l.len == 0) return false;
    const kw = l[0].asAtom() orelse return false;
    return std.mem.eql(u8, kw, "offset") or std.mem.eql(u8, kw, "i32.const") or std.mem.eql(u8, kw, "global.get");
}

/// `(global $name? (export "x")* (import "m" "n")? (mut? valtype) init-expr?)`.
fn parseGlobal(a: std.mem.Allocator, items: []const Sexpr, globals: *List(GlobalDef), global_imports: *List(ImportedGlobal), global_names: *List(?[]const u8), exports: *List(ExportDef), type_names: []const ?[]const u8) Error!void {
    var i: usize = 1;
    var name: ?[]const u8 = null;
    if (i < items.len and isId(items[i])) {
        name = items[i].atom;
        i += 1;
    }
    // The global-space index this entry will occupy (imports precede definitions).
    const idx: u32 = @intCast(global_names.items.len);
    while (i < items.len and eqKw(items[i], "export")) : (i += 1)
        try exports.append(a, .{ .name = try fieldStr(items[i], 1), .kind = 3, .index = idx });
    // Optional inline import: `(import "module" "name")`.
    var imp: ?struct { module: []const u8, name: []const u8 } = null;
    if (i < items.len and eqKw(items[i], "import")) {
        const l = (try wantList(items[i]));
        imp = .{ .module = (try strAt(l, 1)), .name = (try strAt(l, 2)) };
        i += 1;
    }
    // Global type: `valtype` or `(mut valtype)`. A list may be either the
    // mutability wrapper `(mut …)` or a reference type `(ref null? ht)` — the
    // latter is itself the valtype.
    if (i >= items.len) return error.BadModuleField;
    var mutable = false;
    var valtype: V = undefined;
    if (items[i].asList()) |gt| {
        if (gt.len == 0) return error.BadModuleField; // `(global ())` — empty type list
        if (eqAtom(gt[0], "mut")) {
            mutable = true;
            valtype = try parseValType(gt[gt.len - 1], type_names);
        } else {
            valtype = try parseValType(items[i], type_names);
        }
    } else {
        valtype = try parseValType(items[i], type_names);
    }
    i += 1;
    if (imp) |m| {
        try global_imports.append(a, .{ .module = m.module, .name = m.name, .valtype = valtype, .mutable = mutable });
    } else {
        // The init is every remaining form (an empty sequence — a missing init —
        // encodes to a bare `end`, which validation rejects on arity).
        try globals.append(a, .{ .valtype = valtype, .mutable = mutable, .init = items[i..] });
    }
    try global_names.append(a, name);
}

/// Top-level `(import "m" "n" (global $id? (mut? valtype)))`. Only global imports
/// are assembled today; a func/table/memory import errors (honest, not silent).
fn parseImport(a: std.mem.Allocator, items: []const Sexpr, global_imports: *List(ImportedGlobal), global_names: *List(?[]const u8), type_names: []const ?[]const u8) Error!void {
    const module = (try strAt(items, 1));
    const name = (try strAt(items, 2));
    const desc = try wantList(try nth(items, 3));
    const dkw = try wantAtom(try nth(desc, 0));
    if (!std.mem.eql(u8, dkw, "global")) return error.UnsupportedInstr; // func/table/memory imports
    var di: usize = 1;
    var gname: ?[]const u8 = null;
    if (di < desc.len and isId(desc[di])) {
        gname = desc[di].atom;
        di += 1;
    }
    var mutable = false;
    var valtype: V = undefined;
    const gtype = try nth(desc, di);
    if (gtype.asList()) |gt| {
        if (gt.len == 0) return error.BadModuleField;
        mutable = eqAtom(gt[0], "mut");
        valtype = try parseValType(gt[gt.len - 1], type_names);
    } else {
        valtype = try parseValType(gtype, type_names);
    }
    try global_imports.append(a, .{ .module = module, .name = name, .valtype = valtype, .mutable = mutable });
    try global_names.append(a, gname);
}

/// Emit an active segment's offset const-expr + `end`. Unwraps `(offset …)`,
/// accepts a folded const-expr (`(i32.const N)` / `(global.get $g)`), and emits
/// an implicit `i32.const 0` when no offset form is present.
fn emitOffsetExpr(a: std.mem.Allocator, out: *List(u8), sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8, form: ?Sexpr) Error!void {
    if (form) |f| {
        if (f.asList()) |l| {
            if (l.len != 0 and eqAtom(l[0], "offset")) return emitConstExpr(a, out, sigs, type_names, global_names, func_names, l[1..]);
        }
        return emitConstExpr(a, out, sigs, type_names, global_names, func_names, &[_]Sexpr{f});
    }
    try out.append(a, @intFromEnum(Op.i32_const));
    try sleb(a, out, 0);
    try out.append(a, @intFromEnum(Op.end));
}

/// Emit one element-segment const-expr + `end`. Accepts a folded expr form
/// (`(ref.func $f)`) or an `(item …)` wrapper around an instruction sequence.
fn emitElementExpr(a: std.mem.Allocator, out: *List(u8), sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8, form: Sexpr) Error!void {
    var ctx: Ctx = .{ .a = a, .out = out, .local_names = &.{}, .func_names = func_names, .sigs = sigs, .type_names = type_names, .global_names = global_names };
    if (form.asList()) |l| {
        if (l.len != 0 and eqAtom(l[0], "item")) {
            try emitSeq(&ctx, l[1..]); // (item <instr seq>)
            try out.append(a, @intFromEnum(Op.end));
            return;
        }
    }
    try emitExpr(&ctx, form);
    try out.append(a, @intFromEnum(Op.end));
}

/// Emit a constant init expression (a sequence of instruction forms) + `end`.
fn emitConstExpr(a: std.mem.Allocator, out: *List(u8), sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, func_names: []const ?[]const u8, exprs: []const Sexpr) Error!void {
    var ctx: Ctx = .{ .a = a, .out = out, .local_names = &.{}, .func_names = func_names, .sigs = sigs, .type_names = type_names, .global_names = global_names };
    try emitSeq(&ctx, exprs);
    try out.append(a, @intFromEnum(Op.end));
}

fn resolveType(type_names: []const ?[]const u8, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        for (type_names, 0..) |nm, i| {
            if (nm != null and std.mem.eql(u8, nm.?, atom)) return @intCast(i);
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn eqAtom(s: Sexpr, atom: []const u8) bool {
    return if (s.asAtom()) |a| std.mem.eql(u8, a, atom) else false;
}

fn parseFunc(a: std.mem.Allocator, form: []const Sexpr, type_names: []const ?[]const u8) Error!Func {
    var f: Func = .{};
    var i: usize = 1;
    if (i < form.len and isId(form[i])) {
        f.name = form[i].atom;
        i += 1;
    }
    while (i < form.len) : (i += 1) {
        const kw = form[i].keyword() orelse break; // start of the body
        const list = (try wantList(form[i]));
        if (std.mem.eql(u8, kw, "export")) {
            try f.exports.append(a, (try strAt(list, 1)));
        } else if (std.mem.eql(u8, kw, "import")) {
            f.import = .{ .module = (try strAt(list, 1)), .name = (try strAt(list, 2)) }; // (import "m" "n")
        } else if (std.mem.eql(u8, kw, "type")) {
            f.type_ref = try nth(list, 1); // (type $t)
        } else if (std.mem.eql(u8, kw, "param")) {
            try parseDecls(a, list, &f.params, &f.local_names, type_names);
        } else if (std.mem.eql(u8, kw, "result")) {
            try parseDecls(a, list, &f.results, null, type_names);
        } else if (std.mem.eql(u8, kw, "local")) {
            try parseDecls(a, list, &f.locals, &f.local_names, type_names);
        } else break; // body starts (e.g. a folded instruction)
    }
    f.body = form[i..];
    return f;
}

/// Parse a `(param …)` / `(result …)` / `(local …)` group. Handles the named
/// single form `(param $x i32)` and the anonymous multi form `(param i32 i32)`.
fn parseDecls(a: std.mem.Allocator, list: []const Sexpr, out_types: *List(V), out_names: ?*List(?[]const u8), type_names: []const ?[]const u8) Error!void {
    if (list.len >= 3 and isId(list[1])) {
        try out_types.append(a, try parseValType(list[2], type_names));
        if (out_names) |n| try n.append(a, list[1].atom);
    } else {
        for (list[1..]) |t| {
            try out_types.append(a, try parseValType(t, type_names));
            if (out_names) |n| try n.append(a, null);
        }
    }
}

/// True if the S-expression is an identifier atom (`$name`).
fn isId(s: Sexpr) bool {
    const atom = s.asAtom() orelse return false;
    return atom.len != 0 and atom[0] == '$';
}

/// Parse a value type. `type_names` resolves a concrete `(ref null? $t)` /
/// `(ref null? <index>)` to its type index (pass `&.{}` where concrete refs
/// can't occur).
fn parseValType(s: Sexpr, type_names: []const ?[]const u8) Error!V {
    // Reference type spelled as a list: `(ref null? ht)` — `null` marks nullable.
    if (s.asList()) |l| {
        if (l.len >= 2 and eqAtom(l[0], "ref")) {
            const nullable = l.len >= 3 and eqAtom(l[1], "null");
            return heapTypeToValType(l[l.len - 1], nullable, type_names);
        }
        return error.BadValType;
    }
    const atom = s.asAtom() orelse return error.BadValType;
    return stringToValType(atom) orelse error.BadValType;
}

/// A heap type → a reference value type. A concrete `$t` / numeric index → a
/// concrete typed reference carrying that type index; the `func`/`nofunc`
/// families → the func head; the WasmGC `any` hierarchy → its own value types;
/// `extern`/`noextern`/`exn` → the opaque extern head. `nullable` picks the
/// nullable vs non-null variant. (The kind bits of a concrete ref are a
/// placeholder — the assembler only emits its index; the decoder re-derives the
/// family via its kind pre-scan.)
fn heapTypeToValType(s: Sexpr, nullable: bool, type_names: []const ?[]const u8) Error!V {
    const atom = s.asAtom() orelse return error.BadValType;
    // A `$name` or a bare numeric index is a concrete type reference.
    if ((atom.len != 0 and atom[0] == '$') or (atom.len != 0 and std.ascii.isDigit(atom[0]))) {
        // `concreteRef` masks the index to 28 bits, so `(ref 4294967295)` used to
        // become `(ref 0x0fffffff)` silently — and an index just above the mask
        // truncates to a small *valid* one, i.e. type confusion rather than a
        // merely wrong number. The binary decoder bounds this by the declared
        // type count; the text side has no such bound, so check the width here.
        const ti = try resolveType(type_names, s);
        if (ti > V.max_concrete_index) return error.BadImmediate;
        return V.concreteRef(nullable, .@"struct", ti);
    }
    const pair: ?[2]V = if (std.mem.eql(u8, atom, "func") or std.mem.eql(u8, atom, "funcref") or std.mem.eql(u8, atom, "nofunc"))
        .{ .funcref, .funcref_nn }
    else if (std.mem.eql(u8, atom, "extern") or std.mem.eql(u8, atom, "externref") or std.mem.eql(u8, atom, "noextern"))
        .{ .externref, .externref_nn }
    else if (std.mem.eql(u8, atom, "exn") or std.mem.eql(u8, atom, "exnref") or std.mem.eql(u8, atom, "noexn"))
        .{ .exnref, .exnref_nn }
    else if (std.mem.eql(u8, atom, "any") or std.mem.eql(u8, atom, "anyref"))
        .{ .anyref, .anyref_nn }
    else if (std.mem.eql(u8, atom, "eq") or std.mem.eql(u8, atom, "eqref"))
        .{ .eqref, .eqref_nn }
    else if (std.mem.eql(u8, atom, "i31") or std.mem.eql(u8, atom, "i31ref"))
        .{ .i31ref, .i31ref_nn }
    else if (std.mem.eql(u8, atom, "struct") or std.mem.eql(u8, atom, "structref"))
        .{ .structref, .structref_nn }
    else if (std.mem.eql(u8, atom, "array") or std.mem.eql(u8, atom, "arrayref"))
        .{ .arrayref, .arrayref_nn }
    else if (std.mem.eql(u8, atom, "none") or std.mem.eql(u8, atom, "nullref"))
        .{ .nullref, .nullref_nn }
    else
        null;
    const p = pair orelse return error.BadValType;
    return if (nullable) p[0] else p[1];
}

fn stringToValType(atom: []const u8) ?V {
    const map = .{
        .{ "i32", V.i32 },             .{ "i64", V.i64 },             .{ "f32", V.f32 },
        .{ "f64", V.f64 },             .{ "v128", V.v128 },
        .{ "funcref", V.funcref },     .{ "nullfuncref", V.funcref },
        // `anyfunc` is the pre-standard spelling of `funcref` (MVP-era tools and
        // hand-written .wat still emit it, e.g. `(table N anyfunc)`).
        .{ "anyfunc", V.funcref },
        .{ "externref", V.externref }, .{ "nullexternref", V.externref },
        // The WasmGC `any` hierarchy — each shorthand its own value type.
        .{ "anyref", V.anyref },       .{ "eqref", V.eqref },
        .{ "i31ref", V.i31ref },       .{ "structref", V.structref },
        .{ "arrayref", V.arrayref },   .{ "nullref", V.nullref },
        .{ "exnref", V.exnref },       .{ "nullexnref", V.exnref },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, atom, m[0])) return m[1];
    }
    return null;
}

// --- Instruction encoding --------------------------------------------------

const Ctx = struct {
    a: std.mem.Allocator,
    out: *List(u8),
    local_names: []const ?[]const u8,
    func_names: []const ?[]const u8,
    /// Shared type section — multi-value block types intern their signatures here.
    sigs: *List(Sig),
    /// Named type definitions (index-aligned with the type section), for
    /// resolving `(type $t)` in `call_indirect` and type-index block types.
    type_names: []const ?[]const u8,
    /// Global names (index-aligned with the global index space), for resolving
    /// `global.get $g` / `global.set $g`.
    global_names: []const ?[]const u8,
    /// Table names (index-aligned with the table index space), for resolving the
    /// explicit table operand of `call_indirect $t`.
    table_names: []const ?[]const u8 = &.{},
    /// Element-segment names (index-aligned with the element index space), for
    /// resolving `$e` in `table.init` / `elem.drop`.
    elem_names: []const ?[]const u8 = &.{},
    /// Exception-tag names (index-aligned with the tag index space), for
    /// resolving `$e` in `throw $e` and `(catch $e …)` (EH proposal, Phase 6).
    tag_names: []const ?[]const u8 = &.{},
    /// Data-segment names (index-aligned with the data index space), for
    /// resolving `$d` in `memory.init` / `data.drop`.
    data_names: []const ?[]const u8 = &.{},
    /// Memory names (index-aligned with the memory index space, imports first),
    /// for resolving `$m` in a memarg (`i32.load $m …`) and `memory.*` ops.
    mem_names: []const ?[]const u8 = &.{},
    /// Per-type struct field names (indexed by type index; each entry aligned
    /// with that struct's fields), for resolving `struct.get $T $field` by name.
    field_names: []const []const ?[]const u8 = &.{},
    /// Control-flow label stack (innermost last), for resolving `br $name` to a
    /// relative depth.
    labels: List(?[]const u8) = .empty,
};

fn encodeBody(a: std.mem.Allocator, f: Func, func_names: []const ?[]const u8, sigs: *List(Sig), type_names: []const ?[]const u8, global_names: []const ?[]const u8, table_names: []const ?[]const u8, elem_names: []const ?[]const u8, tag_names: []const ?[]const u8, data_names: []const ?[]const u8, mem_names: []const ?[]const u8, field_names: []const []const ?[]const u8) Error![]const u8 {
    var body: List(u8) = .empty;
    // Locals vector: one (count=1, type) group per declared local.
    try uleb(a, &body, f.locals.items.len);
    for (f.locals.items) |t| {
        try uleb(a, &body, 1);
        try emitValType(a, &body, t);
    }
    var ctx: Ctx = .{ .a = a, .out = &body, .local_names = f.local_names.items, .func_names = func_names, .sigs = sigs, .type_names = type_names, .global_names = global_names, .table_names = table_names, .elem_names = elem_names, .tag_names = tag_names, .data_names = data_names, .mem_names = mem_names, .field_names = field_names };
    try emitSeq(&ctx, f.body);
    try body.append(a, @intFromEnum(Op.end)); // implicit function end
    return body.items;
}

/// Emit a sequence of instruction forms (folded lists and/or flat atoms).
fn emitSeq(ctx: *Ctx, items: []const Sexpr) Error!void {
    var i: usize = 0;
    while (i < items.len) i = try emitOne(ctx, items, i);
}

/// Emit one instruction (flat or folded) starting at `items[i]`; return the
/// index of the next instruction.
fn emitOne(ctx: *Ctx, items: []const Sexpr, i: usize) Error!usize {
    return switch (items[i]) {
        .list => |l| emitFoldedOne(ctx, l, i),
        .atom => |name| emitFlatOne(ctx, items, i, name),
        .string => error.UnknownInstr,
    };
}

fn emitExpr(ctx: *Ctx, s: Sexpr) Error!void {
    var one = [_]Sexpr{s};
    _ = try emitOne(ctx, &one, 0);
}

fn emitFoldedOne(ctx: *Ctx, l: []const Sexpr, i: usize) Error!usize {
    const kw = (try nth(l, 0)).asAtom() orelse return error.UnknownInstr;
    // Legacy folded `try` (older-LLVM EH): `try` and `catch` are not enum-named
    // (`try_`/`catch_`), and the form is structural (`(do …)` + clause lists), so
    // it is intercepted here before `lookupOp`. The binary it emits is exactly
    // what the decoder already reads (Phase 6.3), so execution is already proven.
    if (std.mem.eql(u8, kw, "try")) {
        try emitFoldedTry(ctx, l);
        return i + 1;
    }
    if (lookupSimd(kw)) |sd| {
        _ = try emitSimd(ctx, sd, l, 1, true);
        return i + 1;
    }
    if (lookupAtomic(kw)) |sub| {
        _ = try emitAtomic(ctx, sub, l, 1, true);
        return i + 1;
    }
    const op = lookupOp(kw) orelse return error.UnknownInstr;
    switch (op) {
        .block, .loop => try emitFoldedBlock(ctx, op, l),
        .try_table => try emitTryTable(ctx, l),
        .@"if" => try emitFoldedIf(ctx, l),
        .select => try emitFoldedSelect(ctx, l),
        .call_indirect => {
            const ann = try parseCallIndirectType(ctx, l, 1);
            var j = ann.next;
            while (j < l.len) j = try emitOne(ctx, l, j); // operands
            try emitCallIndirect(ctx, ann.idx, ann.table);
        },
        .ref_test, .ref_cast => {
            if (l.len < 2) return error.BadImmediate;
            const rt = try parseRefTypeTarget(ctx, l[1]);
            var j: usize = 2;
            while (j < l.len) j = try emitOne(ctx, l, j); // operand(s)
            try emitRefCast(ctx, op, rt);
        },
        .br_on_cast, .br_on_cast_fail => {
            if (l.len < 4) return error.BadImmediate;
            const label = try resolveLabel(ctx, l[1]);
            const t1 = try parseRefTypeTarget(ctx, l[2]);
            const t2 = try parseRefTypeTarget(ctx, l[3]);
            var j: usize = 4;
            while (j < l.len) j = try emitOne(ctx, l, j); // operand(s)
            try emitBrCast(ctx, op, label, t1, t2);
        },
        else => try emitFoldedPlain(ctx, op, l),
    }
    return i + 1;
}

/// Parse a `call_indirect` type annotation (`(type $t)` and/or inline
/// `(param)(result)`) from `items[start..]`; return its type index + next index.
fn parseCallIndirectType(ctx: *Ctx, items: []const Sexpr, start: usize) Error!struct { idx: u32, table: u32, next: usize } {
    var j = start;
    // Optional explicit table index/id — only when an atom is *followed by* a
    // `(type …)`/`(param …)`/`(result …)` annotation (`call_indirect $t (type …)`).
    // Otherwise a bare atom is the next instruction (e.g. flat `call_indirect select`).
    var table: u32 = 0;
    if (j + 1 < items.len and items[j].asAtom() != null and isTypeUse(items[j + 1])) {
        table = try resolveByName(ctx.table_names, items[j]);
        j += 1;
    }
    var type_ref: ?Sexpr = null;
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    while (j < items.len and items[j].keyword() != null) : (j += 1) {
        const kw = items[j].keyword().?;
        if (std.mem.eql(u8, kw, "type")) type_ref = try nth(try wantList(items[j]), 1) else if (std.mem.eql(u8, kw, "param")) try parseDecls(ctx.a, (try wantList(items[j])), &params, null, ctx.type_names) else if (std.mem.eql(u8, kw, "result")) try parseDecls(ctx.a, (try wantList(items[j])), &results, null, ctx.type_names) else break;
    }
    const idx = if (type_ref) |tr| try resolveType(ctx.type_names, tr) else try internSig(ctx.a, ctx.sigs, params.items, results.items);
    return .{ .idx = idx, .table = table, .next = j };
}

/// True if the form is a `call_indirect` type annotation: `(type …)` /
/// `(param …)` / `(result …)`.
fn isTypeUse(s: Sexpr) bool {
    const kw = s.keyword() orelse return false;
    return std.mem.eql(u8, kw, "type") or std.mem.eql(u8, kw, "param") or std.mem.eql(u8, kw, "result");
}

fn emitCallIndirect(ctx: *Ctx, type_index: u32, table: u32) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(Op.call_indirect));
    try uleb(ctx.a, ctx.out, type_index);
    try uleb(ctx.a, ctx.out, table);
}

/// `(select (result t)* operand*)` — a `(result …)` annotation means typed select.
fn emitFoldedSelect(ctx: *Ctx, l: []const Sexpr) Error!void {
    var j: usize = 1;
    var tys: List(V) = .empty;
    while (j < l.len and eqKw(l[j], "result")) : (j += 1) try parseDecls(ctx.a, (try wantList(l[j])), &tys, null, ctx.type_names);
    while (j < l.len) j = try emitOne(ctx, l, j); // operands
    try emitSelect(ctx, tys.items);
}

fn emitSelect(ctx: *Ctx, tys: []const V) Error!void {
    if (tys.len == 0) {
        try ctx.out.append(ctx.a, @intFromEnum(Op.select));
    } else {
        try ctx.out.append(ctx.a, @intFromEnum(Op.select_t));
        try uleb(ctx.a, ctx.out, tys.len);
        for (tys) |t| try emitValType(ctx.a, ctx.out, t);
    }
}

fn eqKw(s: Sexpr, kw: []const u8) bool {
    return if (s.keyword()) |k| std.mem.eql(u8, k, kw) else false;
}

/// A plain folded instruction: `(op imm* operand*)` — operands emitted first.
fn emitFoldedPlain(ctx: *Ctx, op: Op, l: []const Sexpr) Error!void {
    var i: usize = 1;
    const imm_start = i;
    while (i < l.len and l[i].asAtom() != null) i += 1;
    const immediates = l[imm_start..i];
    while (i < l.len) i = try emitOne(ctx, l, i); // operand sub-expressions
    try emitInstr(ctx, op, immediates);
}

/// `(block|loop $label? blocktype? instr*)`
fn emitFoldedBlock(ctx: *Ctx, op: Op, l: []const Sexpr) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(op));
    var j: usize = 1;
    const label = parseOptLabel(l, &j);
    try emitBlockTypeSig(ctx, try parseBlockTypeSig(ctx, l, &j));
    try ctx.labels.append(ctx.a, label);
    try emitSeq(ctx, l[j..]);
    try ctx.out.append(ctx.a, @intFromEnum(Op.end));
    _ = ctx.labels.pop();
}

/// `(try_table $label? blocktype? (catch|catch_ref $tag $l)* (catch_all|catch_all_ref $l)* instr*)`
fn emitTryTable(ctx: *Ctx, l: []const Sexpr) Error!void {
    try ctx.out.append(ctx.a, @intFromEnum(Op.try_table));
    var j: usize = 1;
    const label = parseOptLabel(l, &j);
    const bt = try parseBlockTypeSig(ctx, l, &j);
    // Push the try_table's own label first so a `(catch … $l)` targeting it
    // resolves to 0 (label 0 = the try_table block); outer labels are > 0.
    try ctx.labels.append(ctx.a, label);
    try emitBlockTypeSig(ctx, bt);
    try emitCatchClauses(ctx, l, &j);
    try emitSeq(ctx, l[j..]);
    try ctx.out.append(ctx.a, @intFromEnum(Op.end));
    _ = ctx.labels.pop();
}

/// Emit a `try_table`'s catch vector: consume leading `(catch …)` / `(catch_ref …)`
/// / `(catch_all …)` / `(catch_all_ref …)` clauses from `items[j..]`, then emit
/// `count` followed by each clause (kind byte, tag index for the non-`all` kinds,
/// label index). `j` is advanced past the clauses.
fn emitCatchClauses(ctx: *Ctx, items: []const Sexpr, j: *usize) Error!void {
    const Clause = struct { kind: u8, tag: ?u32, label: u32 };
    var clauses: List(Clause) = .empty;
    while (j.* < items.len) {
        const cl = items[j.*].asList() orelse break;
        if (cl.len == 0) break;
        const kw = cl[0].asAtom() orelse break;
        const kind: u8 = if (std.mem.eql(u8, kw, "catch"))
            0
        else if (std.mem.eql(u8, kw, "catch_ref"))
            1
        else if (std.mem.eql(u8, kw, "catch_all"))
            2
        else if (std.mem.eql(u8, kw, "catch_all_ref"))
            3
        else
            break;
        if (kind < 2) {
            if (cl.len < 3) return error.BadImmediate;
            try clauses.append(ctx.a, .{ .kind = kind, .tag = try resolveByName(ctx.tag_names, cl[1]), .label = try resolveLabel(ctx, cl[2]) });
        } else {
            if (cl.len < 2) return error.BadImmediate;
            try clauses.append(ctx.a, .{ .kind = kind, .tag = null, .label = try resolveLabel(ctx, cl[1]) });
        }
        j.* += 1;
    }
    try uleb(ctx.a, ctx.out, clauses.items.len);
    for (clauses.items) |c| {
        try ctx.out.append(ctx.a, c.kind);
        if (c.tag) |t| try uleb(ctx.a, ctx.out, t);
        try uleb(ctx.a, ctx.out, c.label);
    }
}

/// Legacy folded `try` (older-LLVM exception handling, Phase 6.3):
///   `(try $label? blocktype? (do instr*) (catch $tag instr*)* (catch_all instr*)?)`
///   `(try $label? blocktype? (do instr*) (delegate $label))`
///
/// Emits the flat legacy encoding the decoder consumes: `try_ bt … catch tag …
/// catch_all … end`, or `try_ bt … delegate label` (delegate replaces `end`).
/// The try's own label is on the stack while the body and handlers are emitted,
/// so a `$label`/`rethrow`/`delegate` operand resolves against the same depth
/// model the interpreter uses at run time.
fn emitFoldedTry(ctx: *Ctx, l: []const Sexpr) Error!void {
    var j: usize = 1;
    const label = parseOptLabel(l, &j);
    const bt = try parseBlockTypeSig(ctx, l, &j);

    if (j >= l.len) return error.BadImmediate;
    const do_form = l[j].asList() orelse return error.BadImmediate;
    if (do_form.len == 0 or !eqAtom(do_form[0], "do")) return error.BadImmediate;
    j += 1;

    try ctx.out.append(ctx.a, @intFromEnum(Op.try_));
    try emitBlockTypeSig(ctx, bt);
    try ctx.labels.append(ctx.a, label);
    try emitSeq(ctx, do_form[1..]);

    // A `(delegate $l)` forwards an exception to an enclosing try in place of
    // running local handlers. The RUNTIME does not implement that routing —
    // `precomputeControlFlow` records the delegate label but `throwException`
    // never consults it, so a delegated exception unwinds as if the delegate
    // weren't there. Emitting it would assemble a module that VALIDATES yet
    // silently mis-routes at run time, which is exactly the "bytes don't match
    // the source" failure this assembler refuses elsewhere. Reject loudly until
    // the interpreter routes it. (No corpus file uses it; `catch`/`catch_all`/
    // `rethrow` are fully supported.)
    if (j < l.len) if (l[j].asList()) |d| {
        if (d.len != 0 and eqAtom(d[0], "delegate")) return error.UnsupportedInstr;
    };

    while (j < l.len) : (j += 1) {
        const cl = l[j].asList() orelse return error.BadImmediate;
        if (cl.len == 0) return error.BadImmediate;
        const ckw = cl[0].asAtom() orelse return error.BadImmediate;
        if (std.mem.eql(u8, ckw, "catch")) {
            if (cl.len < 2) return error.BadImmediate;
            try ctx.out.append(ctx.a, @intFromEnum(Op.catch_));
            try uleb(ctx.a, ctx.out, try resolveByName(ctx.tag_names, cl[1]));
            try emitSeq(ctx, cl[2..]);
        } else if (std.mem.eql(u8, ckw, "catch_all")) {
            try ctx.out.append(ctx.a, @intFromEnum(Op.catch_all));
            try emitSeq(ctx, cl[1..]);
        } else return error.BadImmediate; // only catch/catch_all/delegate may follow `(do …)`
    }
    try ctx.out.append(ctx.a, @intFromEnum(Op.end));
    _ = ctx.labels.pop();
}

/// `(if $label? blocktype? cond? (then instr*) (else instr*)?)`
fn emitFoldedIf(ctx: *Ctx, l: []const Sexpr) Error!void {
    var j: usize = 1;
    const label = parseOptLabel(l, &j);
    const bt = try parseBlockTypeSig(ctx, l, &j);

    // An optional folded condition precedes `(then …)`; emit it first.
    if (j < l.len) {
        if (l[j].keyword()) |kw| {
            if (!std.mem.eql(u8, kw, "then") and !std.mem.eql(u8, kw, "else")) {
                try emitExpr(ctx, l[j]);
                j += 1;
            }
        }
    }
    if (j >= l.len) return error.BadImmediate;
    const then_form = l[j].asList() orelse return error.BadImmediate;
    if (then_form.len == 0) return error.BadImmediate; // must be `(then …)`, not `()`
    j += 1;
    const else_form: ?[]const Sexpr = if (j < l.len) l[j].asList() else null;

    try ctx.out.append(ctx.a, @intFromEnum(Op.@"if"));
    try emitBlockTypeSig(ctx, bt);
    try ctx.labels.append(ctx.a, label);
    try emitSeq(ctx, then_form[1..]);
    if (else_form) |ef| {
        if (ef.len == 0) return error.BadImmediate; // `(else …)`, not `()`
        try ctx.out.append(ctx.a, @intFromEnum(Op.@"else"));
        try emitSeq(ctx, ef[1..]);
    }
    try ctx.out.append(ctx.a, @intFromEnum(Op.end));
    _ = ctx.labels.pop();
}

/// A flat instruction at `items[i]` (`name` is its atom); return the next index.
fn emitFlatOne(ctx: *Ctx, items: []const Sexpr, i: usize, name: []const u8) Error!usize {
    if (lookupSimd(name)) |sd| return emitSimd(ctx, sd, items, i + 1, false);
    if (lookupAtomic(name)) |sub| return emitAtomic(ctx, sub, items, i + 1, false);
    const op = lookupOp(name) orelse return error.UnknownInstr;
    switch (op) {
        .block, .loop, .@"if" => {
            try ctx.out.append(ctx.a, @intFromEnum(op));
            var j = i + 1;
            const label = parseOptLabel(items, &j);
            try emitBlockTypeSig(ctx, try parseBlockTypeSig(ctx, items, &j));
            try ctx.labels.append(ctx.a, label);
            return j;
        },
        .try_table => {
            // Flat: `try_table $l? blocktype? catch* … end`. Push the label before
            // resolving the catch labels (label 0 = the try_table itself); the
            // body instructions follow and the eventual `end` pops the label.
            try ctx.out.append(ctx.a, @intFromEnum(op));
            var j = i + 1;
            const label = parseOptLabel(items, &j);
            const bt = try parseBlockTypeSig(ctx, items, &j);
            try ctx.labels.append(ctx.a, label);
            try emitBlockTypeSig(ctx, bt);
            try emitCatchClauses(ctx, items, &j);
            return j;
        },
        .@"else" => {
            try ctx.out.append(ctx.a, @intFromEnum(Op.@"else"));
            return i + 1;
        },
        .end => {
            try ctx.out.append(ctx.a, @intFromEnum(Op.end));
            if (ctx.labels.items.len != 0) _ = ctx.labels.pop();
            return i + 1;
        },
        .br_table => {
            try ctx.out.append(ctx.a, @intFromEnum(Op.br_table));
            var j = i + 1;
            var labels: List(Sexpr) = .empty;
            // `asAtom() != null` swallowed the FOLLOWING INSTRUCTIONS as labels
            // (`end`, `i32.const`, `return` … are all atoms), so `resolveLabel`
            // then failed and flat `br_table` could never assemble — despite the
            // module header claiming flat `br*` support, and despite this being
            // `wasm2wat`'s default output shape. `isIndexAtom` is the right
            // predicate and the sibling `.table_init`/`.elem_drop`/`.table_copy`
            // arm already uses it.
            while (j < items.len and isIndexAtom(items[j])) : (j += 1) {
                try labels.append(ctx.a, items[j]);
            }
            try emitBrTable(ctx, labels.items);
            return j;
        },
        .select => {
            var j = i + 1;
            var tys: List(V) = .empty;
            while (j < items.len and eqKw(items[j], "result")) : (j += 1) try parseDecls(ctx.a, (try wantList(items[j])), &tys, null, ctx.type_names);
            try emitSelect(ctx, tys.items);
            return j;
        },
        .call_indirect => {
            const ann = try parseCallIndirectType(ctx, items, i + 1);
            try emitCallIndirect(ctx, ann.idx, ann.table);
            return ann.next;
        },
        .ref_test, .ref_cast => {
            if (i + 1 >= items.len) return error.BadImmediate;
            try emitRefCast(ctx, op, try parseRefTypeTarget(ctx, items[i + 1]));
            return i + 2;
        },
        .br_on_cast, .br_on_cast_fail => {
            if (i + 3 >= items.len) return error.BadImmediate;
            const label = try resolveLabel(ctx, items[i + 1]);
            const t1 = try parseRefTypeTarget(ctx, items[i + 2]);
            const t2 = try parseRefTypeTarget(ctx, items[i + 3]);
            try emitBrCast(ctx, op, label, t1, t2);
            return i + 4;
        },
        .table_get, .table_set, .table_grow, .table_size, .table_fill => {
            try emitOpcode(ctx, op);
            // Optional explicit table index/id; a `$name` or numeric atom (a
            // following instruction is never either), else default table 0.
            var j = i + 1;
            var t: u32 = 0;
            if (j < items.len) if (items[j].asAtom()) |atom| {
                if (atom.len != 0 and (atom[0] == '$' or std.ascii.isDigit(atom[0]))) {
                    t = try resolveByName(ctx.table_names, items[j]);
                    j += 1;
                }
            };
            try uleb(ctx.a, ctx.out, t);
            return j;
        },
        .table_init, .elem_drop, .table_copy => {
            // Consume the leading index atoms (0–2), then the bulk-op immediate
            // encoder (shared with the folded path) resolves + emits them.
            var idxs: [2]Sexpr = undefined;
            var n: usize = 0;
            var j = i + 1;
            while (j < items.len and n < 2 and isIndexAtom(items[j])) : (j += 1) {
                idxs[n] = items[j];
                n += 1;
            }
            try emitOpcode(ctx, op);
            try emitBulkTableImm(ctx, op, idxs[0..n]);
            return j;
        },
        else => {
            var buf: [4]Sexpr = undefined;
            var n: usize = 0;
            var j = i + 1;
            const kind = opcode.immediateKind(op);
            if (kind == .mem) {
                // memarg: an optional leading memory index (multi-memory), then
                // `offset=`/`align=` atoms in any order.
                while (j < items.len and n < buf.len) : (j += 1) {
                    const atom = items[j].asAtom() orelse break;
                    const is_memarg = std.mem.startsWith(u8, atom, "offset=") or std.mem.startsWith(u8, atom, "align=");
                    const is_memidx = n == 0 and isIndexAtom(items[j]);
                    if (!is_memarg and !is_memidx) break;
                    buf[n] = items[j];
                    n += 1;
                }
            } else if (kind == .mem_index or kind == .mem_reserved or kind == .data_init or kind == .mem_copy) {
                // Optional memory index(es) — `memory.size/grow/fill $m`,
                // `memory.copy $dst $src`, `memory.init $mem $data`. Collect every
                // leading index atom; `emitInstr` interprets them by count.
                while (j < items.len and n < buf.len and isIndexAtom(items[j])) : (j += 1) {
                    buf[n] = items[j];
                    n += 1;
                }
            } else {
                for (0..flatImmCount(op)) |_| {
                    if (j >= items.len) return error.BadImmediate;
                    buf[n] = items[j];
                    n += 1;
                    j += 1;
                }
            }
            try emitInstr(ctx, op, buf[0..n]);
            return j;
        },
    }
}

/// True if the s-expr is an index atom — a `$name` or a numeric literal — as
/// opposed to a folded operand list or a following instruction keyword.
fn isIndexAtom(s: Sexpr) bool {
    const atom = s.asAtom() orelse return false;
    return atom.len != 0 and (atom[0] == '$' or std.ascii.isDigit(atom[0]));
}

fn parseOptLabel(l: []const Sexpr, j: *usize) ?[]const u8 {
    if (j.* < l.len) {
        if (l[j.*].asAtom()) |atom| {
            if (atom.len != 0 and atom[0] == '$') {
                j.* += 1;
                return atom;
            }
        }
    }
    return null;
}

/// A parsed block type: either a `(type $t)` reference (`type_ref`) or an inline
/// `(param …)(result …)` signature.
const BlockTy = struct { type_ref: ?u32 = null, sig: Sig = .{ .params = &.{}, .results = &.{} } };

/// Parse a block type — a `(type $t)` reference and/or consecutive
/// `(param …)` / `(result …)` forms.
fn parseBlockTypeSig(ctx: *Ctx, l: []const Sexpr, j: *usize) Error!BlockTy {
    var type_ref: ?u32 = null;
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    while (j.* < l.len) {
        const kw = l[j.*].keyword() orelse break;
        if (std.mem.eql(u8, kw, "type")) {
            type_ref = try resolveType(ctx.type_names, try nth(try wantList(l[j.*]), 1));
        } else if (std.mem.eql(u8, kw, "param")) {
            try parseDecls(ctx.a, try wantList(l[j.*]), &params, null, ctx.type_names);
        } else if (std.mem.eql(u8, kw, "result")) {
            try parseDecls(ctx.a, try wantList(l[j.*]), &results, null, ctx.type_names);
        } else break;
        j.* += 1;
    }
    return .{ .type_ref = type_ref, .sig = .{ .params = params.items, .results = results.items } };
}

/// Emit a block type: an explicit `(type $t)` reference → its type index; empty →
/// `0x40`; a single result → the value-type byte; params or multiple results →
/// an interned type index.
fn emitBlockTypeSig(ctx: *Ctx, bt: BlockTy) Error!void {
    if (bt.type_ref) |ti| {
        try sleb(ctx.a, ctx.out, ti);
        return;
    }
    const sig = bt.sig;
    if (sig.params.len == 0 and sig.results.len == 0) {
        try ctx.out.append(ctx.a, 0x40);
    } else if (sig.params.len == 0 and sig.results.len == 1 and !sig.results[0].isConcrete()) {
        // Single non-concrete result → the value-type byte form. A concrete ref
        // can't use the single-byte form (its `0x64 ti` would be misread as an
        // s33 block type), so it falls through to an interned type index.
        try ctx.out.append(ctx.a, @intCast(@intFromEnum(sig.results[0])));
    } else {
        try sleb(ctx.a, ctx.out, try internSig(ctx.a, ctx.sigs, sig.params, sig.results));
    }
}

fn emitBrTable(ctx: *Ctx, labels: []const Sexpr) Error!void {
    if (labels.len == 0) return error.BadImmediate; // needs at least a default
    try uleb(ctx.a, ctx.out, labels.len - 1);
    for (labels[0 .. labels.len - 1]) |lab| try uleb(ctx.a, ctx.out, try resolveLabel(ctx, lab));
    try uleb(ctx.a, ctx.out, try resolveLabel(ctx, labels[labels.len - 1]));
}

/// Emit an opcode's bytes: a `0xFC`-prefixed pair for table ops, a `0xFB`-prefixed
/// pair for GC ops, else the single enum byte.
fn emitOpcode(ctx: *Ctx, op: Op) Error!void {
    if (opcode.fcSubOpcode(op)) |sub| {
        try ctx.out.append(ctx.a, 0xfc);
        try uleb(ctx.a, ctx.out, sub);
    } else if (opcode.gcSubOpcode(op)) |sub| {
        try ctx.out.append(ctx.a, 0xfb);
        try uleb(ctx.a, ctx.out, sub);
    } else {
        try ctx.out.append(ctx.a, @intFromEnum(op));
    }
}

/// A parsed `ref.test`/`ref.cast` target: nullability + the heap-type `s33`
/// code to emit (negative = abstract head, non-negative = a type index).
const RefTypeTarget = struct { nullable: bool, code: i64 };

/// Parse a `ref.test`/`ref.cast` target reference type: a shorthand atom
/// (`anyref`/`structref`/…) or a `(ref null? ht)` list whose heap type is an
/// abstract head or a concrete `$t`/index.
fn parseRefTypeTarget(ctx: *Ctx, s: Sexpr) Error!RefTypeTarget {
    if (s.asAtom()) |atom| return shorthandRefType(atom) orelse error.BadValType;
    const l = s.asList() orelse return error.BadValType;
    if (l.len < 2 or !eqAtom(l[0], "ref")) return error.BadValType;
    const nullable = l.len >= 3 and eqAtom(l[1], "null");
    const ht = l[l.len - 1];
    const atom = ht.asAtom() orelse return error.BadValType;
    if (abstractHeapCode(atom)) |c| return .{ .nullable = nullable, .code = c };
    return .{ .nullable = nullable, .code = @intCast(try resolveType(ctx.type_names, ht)) };
}

/// The `s33` heap-type code for an abstract heap-type atom, or null.
fn abstractHeapCode(atom: []const u8) ?i64 {
    const map = .{
        .{ "any", -0x12 },  .{ "eq", -0x13 },     .{ "i31", -0x14 },
        .{ "struct", -0x15 }, .{ "array", -0x16 }, .{ "none", -0x0f },
        .{ "func", -0x10 }, .{ "extern", -0x11 }, .{ "nofunc", -0x0d },
        .{ "noextern", -0x0e },
    };
    inline for (map) |m| if (std.mem.eql(u8, atom, m[0])) return m[1];
    return null;
}

/// A shorthand reference-type atom (`anyref`/…) → nullable target + code.
fn shorthandRefType(atom: []const u8) ?RefTypeTarget {
    const map = .{
        .{ "anyref", -0x12 },  .{ "eqref", -0x13 },      .{ "i31ref", -0x14 },
        .{ "structref", -0x15 }, .{ "arrayref", -0x16 }, .{ "nullref", -0x0f },
        .{ "funcref", -0x10 }, .{ "externref", -0x11 },  .{ "nullfuncref", -0x0d },
        .{ "nullexternref", -0x0e },
    };
    inline for (map) |m| if (std.mem.eql(u8, atom, m[0])) return .{ .nullable = true, .code = m[1] };
    return null;
}

/// Emit a `ref.test`/`ref.cast`: `0xFB`, the null/non-null sub-opcode, then the
/// target heap type as an `s33`.
fn emitRefCast(ctx: *Ctx, op: Op, t: RefTypeTarget) Error!void {
    try ctx.out.append(ctx.a, 0xfb);
    const sub: u8 = switch (op) {
        .ref_test => if (t.nullable) 0x15 else 0x14,
        .ref_cast => if (t.nullable) 0x17 else 0x16,
        else => unreachable,
    };
    try ctx.out.append(ctx.a, sub);
    try sleb(ctx.a, ctx.out, t.code);
}

/// Emit a `br_on_cast`/`br_on_cast_fail`: `0xFB`, the sub-opcode, a flags byte
/// (bit 0 = src nullable, bit 1 = dst nullable), the label, then src & dst heap
/// types as `s33`.
fn emitBrCast(ctx: *Ctx, op: Op, label: u32, src: RefTypeTarget, dst: RefTypeTarget) Error!void {
    try ctx.out.append(ctx.a, 0xfb);
    try ctx.out.append(ctx.a, if (op == .br_on_cast) 0x18 else 0x19);
    const flags: u8 = (@as(u8, @intFromBool(src.nullable))) | (@as(u8, @intFromBool(dst.nullable)) << 1);
    try ctx.out.append(ctx.a, flags);
    try uleb(ctx.a, ctx.out, label);
    try sleb(ctx.a, ctx.out, src.code);
    try sleb(ctx.a, ctx.out, dst.code);
}

/// Emit the immediate operands of a bulk table op from its leading index atoms
/// (`idxs`, 0–2 of them). Text operand order differs from binary: `table.init`
/// is written `tableidx? elemidx` but encoded elem-then-table; `table.copy` is
/// `dst? src?` in both. Shared by the flat and folded emit paths.
fn emitBulkTableImm(ctx: *Ctx, op: Op, idxs: []const Sexpr) Error!void {
    switch (op) {
        .table_init => {
            if (idxs.len == 0) return error.BadImmediate;
            const table: u32 = if (idxs.len >= 2) try resolveByName(ctx.table_names, idxs[0]) else 0;
            const elem: u32 = try resolveByName(ctx.elem_names, idxs[idxs.len - 1]);
            try uleb(ctx.a, ctx.out, elem);
            try uleb(ctx.a, ctx.out, table);
        },
        .elem_drop => {
            if (idxs.len == 0) return error.BadImmediate;
            try uleb(ctx.a, ctx.out, try resolveByName(ctx.elem_names, idxs[0]));
        },
        .table_copy => {
            const dst: u32 = if (idxs.len >= 1) try resolveByName(ctx.table_names, idxs[0]) else 0;
            const src: u32 = if (idxs.len >= 2) try resolveByName(ctx.table_names, idxs[1]) else 0;
            try uleb(ctx.a, ctx.out, dst);
            try uleb(ctx.a, ctx.out, src);
        },
        else => unreachable,
    }
}

fn emitInstr(ctx: *Ctx, op: Op, immediates: []const Sexpr) Error!void {
    try emitOpcode(ctx, op);
    // call_ref / return_call_ref carry a *type* index (the ref's signature), not
    // a func index — resolve it against the type names.
    if (op == .call_ref or op == .return_call_ref) {
        try uleb(ctx.a, ctx.out, try resolveType(ctx.type_names, try imm0(immediates)));
        return;
    }
    switch (opcode.immediateKind(op)) {
        .none => {},
        .local => try uleb(ctx.a, ctx.out, try resolveLocal(ctx, try imm0(immediates))),
        .global => try uleb(ctx.a, ctx.out, try resolveByName(ctx.global_names, try imm0(immediates))),
        .table => try uleb(ctx.a, ctx.out, if (immediates.len == 0) 0 else try resolveByName(ctx.table_names, immediates[0])),
        .func => try uleb(ctx.a, ctx.out, try resolveFunc(ctx, try imm0(immediates))),
        .label => try uleb(ctx.a, ctx.out, try resolveLabel(ctx, try imm0(immediates))),
        .tag => try uleb(ctx.a, ctx.out, try resolveByName(ctx.tag_names, try imm0(immediates))), // throw <tag>

        .i32c => try sleb(ctx.a, ctx.out, try parseWatI32(try imm0(immediates))),
        .i64c => try sleb(ctx.a, ctx.out, try parseWatI64(try imm0(immediates))),
        .f32c => try floatBits(ctx, u32, try imm0(immediates)),
        .f64c => try floatBits(ctx, u64, try imm0(immediates)),
        .mem => try emitMemArg(ctx, op, immediates),
        // memory.fill: an optional memory index (multi-memory), default 0.
        .mem_reserved => try uleb(ctx.a, ctx.out, try memOperand(ctx, immediates, 0)),
        // `memory.size`/`memory.grow`/`memory.fill`: an optional memory index
        // (multi-memory), default 0. Resolved via `mem_names`, so a `$name` or a
        // real index works and an unknown one is `UnknownIdentifier`.
        .mem_index => try uleb(ctx.a, ctx.out, try memOperand(ctx, immediates, 0)),
        // Bulk memory: a data index (+ a memory index). `resolveByName`, not
        // `parseIndex`: data was the only index space whose operand was
        // numeric-only, so `data.drop $d` / `memory.init $d` failed with
        // `BadImmediate` while `elem.drop $e` / `table.init $e` resolved.
        .data => try uleb(ctx.a, ctx.out, try resolveByName(ctx.data_names, try imm0(immediates))),
        // `memory.init <memidx>? <dataidx>`: two immediates = [mem, data]; one =
        // [data], mem 0. The binary is data index then memory index.
        .data_init => {
            if (immediates.len >= 2) {
                try uleb(ctx.a, ctx.out, try resolveByName(ctx.data_names, immediates[1]));
                try uleb(ctx.a, ctx.out, try resolveByName(ctx.mem_names, immediates[0]));
            } else {
                try uleb(ctx.a, ctx.out, try resolveByName(ctx.data_names, try imm0(immediates)));
                try ctx.out.append(ctx.a, 0x00); // memory 0
            }
        },
        // `memory.copy <dstmem>? <srcmem>?`: dst then src, each default 0.
        .mem_copy => {
            try uleb(ctx.a, ctx.out, try memOperand(ctx, immediates, 0));
            try uleb(ctx.a, ctx.out, try memOperand(ctx, immediates, 1));
        },
        // ref.null takes a heap type as an `s33`: an abstract head code, or a
        // concrete `$t` / index (so `ref.null $t` is typed `(ref null $t)`).
        .ref_type => {
            const ht = try imm0(immediates);
            const atom = ht.asAtom() orelse return error.BadImmediate;
            if (abstractHeapCode(atom)) |code| {
                try sleb(ctx.a, ctx.out, code);
            } else {
                try sleb(ctx.a, ctx.out, @intCast(try resolveType(ctx.type_names, ht)));
            }
        },
        .br_table => try emitBrTable(ctx, immediates),
        .table_init, .elem, .table_copy => try emitBulkTableImm(ctx, op, immediates),
        // GC: a type index, optionally followed by a field index / element count.
        .gc_type => try uleb(ctx.a, ctx.out, try resolveType(ctx.type_names, try imm0(immediates))),
        .gc_field => {
            if (immediates.len < 2) return error.BadImmediate;
            const ti = try resolveType(ctx.type_names, immediates[0]);
            try uleb(ctx.a, ctx.out, ti);
            // A field is named (`struct.get $T $field`) or numeric. Resolve a
            // `$name` against that type's field names; the numeric form is
            // untouched (`resolveByName` passes a plain index through).
            const type_fields: []const ?[]const u8 = if (ti < ctx.field_names.len) ctx.field_names[ti] else &.{};
            try uleb(ctx.a, ctx.out, try resolveByName(type_fields, immediates[1]));
        },
        .gc_type_n => {
            if (immediates.len < 2) return error.BadImmediate;
            try uleb(ctx.a, ctx.out, try resolveType(ctx.type_names, immediates[0]));
            try uleb(ctx.a, ctx.out, try resolveByName(&.{}, immediates[1])); // element count
        },
        else => return error.UnsupportedInstr, // block_type (handled structurally), call_indirect
    }
}

fn resolveLabel(ctx: *Ctx, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        var k = ctx.labels.items.len;
        while (k > 0) {
            k -= 1;
            if (ctx.labels.items[k]) |nm| {
                if (std.mem.eql(u8, nm, atom)) return @intCast(ctx.labels.items.len - 1 - k);
            }
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn emitMemArg(ctx: *Ctx, op: Op, immediates: []const Sexpr) Error!void {
    var offset: u64 = 0;
    var align_log2: u32 = opcode.naturalAlignLog2(op);
    var mem_idx: u32 = 0;
    for (immediates) |imm| {
        // A non-atom here is an operand sub-expression in the folded form, not a
        // memarg — skip those. An ATOM is either `offset=`/`align=`, or (once) a
        // leading memory index (multi-memory). A typo must not be ignored: it
        // silently loaded the wrong address — `(i32.load offest=4 (i32.const 0))`
        // read offset 0 — so anything else is `BadImmediate`.
        const atom = imm.asAtom() orelse continue;
        if (std.mem.startsWith(u8, atom, "offset=")) {
            offset = std.fmt.parseInt(u64, atom[7..], 0) catch return error.BadImmediate;
        } else if (std.mem.startsWith(u8, atom, "align=")) {
            const bytes = std.fmt.parseInt(u32, atom[6..], 0) catch return error.BadImmediate;
            // Alignment must be a non-zero power of two (§6.5.8); otherwise
            // `@ctz` would silently encode a bogus log2 (e.g. align=3 → 0).
            if (bytes == 0 or (bytes & (bytes - 1)) != 0) return error.BadImmediate;
            align_log2 = @ctz(bytes);
        } else if (isIndexAtom(imm)) {
            mem_idx = try resolveByName(ctx.mem_names, imm); // explicit memory index
        } else {
            return error.BadImmediate;
        }
    }
    try emitMemArgBytes(ctx, align_log2, mem_idx, offset);
}

/// Emit an encoded memarg: `align` (with bit 6 set + an explicit memory index
/// when `mem_idx != 0` — multi-memory) followed by the u64 offset. Shared by the
/// scalar (`emitMemArg`) and SIMD (`emitSimd`) paths so the encoding can't drift.
fn emitMemArgBytes(ctx: *Ctx, align_log2: u32, mem_idx: u32, offset: u64) Error!void {
    // Natural alignment is ≤ 4, so bit 6 is free to flag the explicit index.
    if (mem_idx != 0) {
        try uleb(ctx.a, ctx.out, align_log2 | 0x40);
        try uleb(ctx.a, ctx.out, mem_idx);
    } else {
        try uleb(ctx.a, ctx.out, align_log2);
    }
    try uleb(ctx.a, ctx.out, offset);
}

/// Resolve the memory index at `immediates[idx]` (a `$name` or numeric index)
/// against the memory name table, or 0 if that operand is absent — the
/// multi-memory default for `memory.size`/`grow`/`fill`/`copy`.
fn memOperand(ctx: *Ctx, immediates: []const Sexpr, idx: usize) Error!u32 {
    if (idx >= immediates.len) return 0;
    return resolveByName(ctx.mem_names, immediates[idx]);
}

/// The first immediate of an instruction, or `BadImmediate` if it has none.
fn imm0(immediates: []const Sexpr) Error!Sexpr {
    if (immediates.len == 0) return error.BadImmediate;
    return immediates[0];
}

/// How many flat immediate atoms an opcode consumes (MVP-supported kinds).
fn flatImmCount(op: Op) usize {
    return switch (opcode.immediateKind(op)) {
        .local, .global, .func, .label, .i32c, .i64c, .f32c, .f64c, .ref_type, .gc_type => 1,
        .data, .data_init => 1, // memory.init / data.drop: a data index
        .tag => 1, // throw <tagidx>
        .gc_field, .gc_type_n => 2,
        else => 0,
    };
}

// --- SIMD (v128) assembly (Phase 8) ----------------------------------------
// Every 0xFD op is one `Op.simd` with a sub-opcode, so `lookupOp`/`stringToEnum`
// can't reach them; this table maps the text name → sub-opcode + immediate shape.
const SimdImm = enum { none, mem, mem_lane, lane, const_, shuffle };
const SimdOp = struct { sub: u32, imm: SimdImm };

fn lookupSimd(name: []const u8) ?SimdOp {
    const E = struct { n: []const u8, s: u32, i: SimdImm };
    const tbl = [_]E{
        .{ .n = "v128.load", .s = 0x00, .i = .mem },       .{ .n = "v128.store", .s = 0x0b, .i = .mem },
        .{ .n = "v128.load8x8_s", .s = 0x01, .i = .mem },  .{ .n = "v128.load8x8_u", .s = 0x02, .i = .mem },
        .{ .n = "v128.load16x4_s", .s = 0x03, .i = .mem }, .{ .n = "v128.load16x4_u", .s = 0x04, .i = .mem },
        .{ .n = "v128.load32x2_s", .s = 0x05, .i = .mem }, .{ .n = "v128.load32x2_u", .s = 0x06, .i = .mem },
        .{ .n = "v128.load8_splat", .s = 0x07, .i = .mem }, .{ .n = "v128.load16_splat", .s = 0x08, .i = .mem },
        .{ .n = "v128.load32_splat", .s = 0x09, .i = .mem }, .{ .n = "v128.load64_splat", .s = 0x0a, .i = .mem },
        .{ .n = "v128.load32_zero", .s = 0x5c, .i = .mem }, .{ .n = "v128.load64_zero", .s = 0x5d, .i = .mem },
        .{ .n = "v128.load8_lane", .s = 0x54, .i = .mem_lane }, .{ .n = "v128.load16_lane", .s = 0x55, .i = .mem_lane },
        .{ .n = "v128.load32_lane", .s = 0x56, .i = .mem_lane }, .{ .n = "v128.load64_lane", .s = 0x57, .i = .mem_lane },
        .{ .n = "v128.store8_lane", .s = 0x58, .i = .mem_lane }, .{ .n = "v128.store16_lane", .s = 0x59, .i = .mem_lane },
        .{ .n = "v128.store32_lane", .s = 0x5a, .i = .mem_lane }, .{ .n = "v128.store64_lane", .s = 0x5b, .i = .mem_lane },
        .{ .n = "v128.const", .s = 0x0c, .i = .const_ },    .{ .n = "i8x16.shuffle", .s = 0x0d, .i = .shuffle },
        .{ .n = "i8x16.swizzle", .s = 0x0e, .i = .none },
        .{ .n = "i8x16.splat", .s = 0x0f, .i = .none },     .{ .n = "i16x8.splat", .s = 0x10, .i = .none },
        .{ .n = "i32x4.splat", .s = 0x11, .i = .none },     .{ .n = "i64x2.splat", .s = 0x12, .i = .none },
        .{ .n = "f32x4.splat", .s = 0x13, .i = .none },     .{ .n = "f64x2.splat", .s = 0x14, .i = .none },
        .{ .n = "i8x16.extract_lane_s", .s = 0x15, .i = .lane }, .{ .n = "i8x16.extract_lane_u", .s = 0x16, .i = .lane },
        .{ .n = "i8x16.replace_lane", .s = 0x17, .i = .lane },   .{ .n = "i16x8.extract_lane_s", .s = 0x18, .i = .lane },
        .{ .n = "i16x8.extract_lane_u", .s = 0x19, .i = .lane }, .{ .n = "i16x8.replace_lane", .s = 0x1a, .i = .lane },
        .{ .n = "i32x4.extract_lane", .s = 0x1b, .i = .lane },   .{ .n = "i32x4.replace_lane", .s = 0x1c, .i = .lane },
        .{ .n = "i64x2.extract_lane", .s = 0x1d, .i = .lane },   .{ .n = "i64x2.replace_lane", .s = 0x1e, .i = .lane },
        .{ .n = "f32x4.extract_lane", .s = 0x1f, .i = .lane },   .{ .n = "f32x4.replace_lane", .s = 0x20, .i = .lane },
        .{ .n = "f64x2.extract_lane", .s = 0x21, .i = .lane },   .{ .n = "f64x2.replace_lane", .s = 0x22, .i = .lane },
        .{ .n = "i8x16.eq", .s = 0x23, .i = .none }, .{ .n = "i8x16.ne", .s = 0x24, .i = .none }, .{ .n = "i8x16.lt_s", .s = 0x25, .i = .none }, .{ .n = "i8x16.lt_u", .s = 0x26, .i = .none }, .{ .n = "i8x16.gt_s", .s = 0x27, .i = .none }, .{ .n = "i8x16.gt_u", .s = 0x28, .i = .none }, .{ .n = "i8x16.le_s", .s = 0x29, .i = .none }, .{ .n = "i8x16.le_u", .s = 0x2a, .i = .none }, .{ .n = "i8x16.ge_s", .s = 0x2b, .i = .none }, .{ .n = "i8x16.ge_u", .s = 0x2c, .i = .none },
        .{ .n = "i16x8.eq", .s = 0x2d, .i = .none }, .{ .n = "i16x8.ne", .s = 0x2e, .i = .none }, .{ .n = "i16x8.lt_s", .s = 0x2f, .i = .none }, .{ .n = "i16x8.lt_u", .s = 0x30, .i = .none }, .{ .n = "i16x8.gt_s", .s = 0x31, .i = .none }, .{ .n = "i16x8.gt_u", .s = 0x32, .i = .none }, .{ .n = "i16x8.le_s", .s = 0x33, .i = .none }, .{ .n = "i16x8.le_u", .s = 0x34, .i = .none }, .{ .n = "i16x8.ge_s", .s = 0x35, .i = .none }, .{ .n = "i16x8.ge_u", .s = 0x36, .i = .none },
        .{ .n = "i32x4.eq", .s = 0x37, .i = .none }, .{ .n = "i32x4.ne", .s = 0x38, .i = .none }, .{ .n = "i32x4.lt_s", .s = 0x39, .i = .none }, .{ .n = "i32x4.lt_u", .s = 0x3a, .i = .none }, .{ .n = "i32x4.gt_s", .s = 0x3b, .i = .none }, .{ .n = "i32x4.gt_u", .s = 0x3c, .i = .none }, .{ .n = "i32x4.le_s", .s = 0x3d, .i = .none }, .{ .n = "i32x4.le_u", .s = 0x3e, .i = .none }, .{ .n = "i32x4.ge_s", .s = 0x3f, .i = .none }, .{ .n = "i32x4.ge_u", .s = 0x40, .i = .none },
        .{ .n = "f32x4.eq", .s = 0x41, .i = .none }, .{ .n = "f32x4.ne", .s = 0x42, .i = .none }, .{ .n = "f32x4.lt", .s = 0x43, .i = .none }, .{ .n = "f32x4.gt", .s = 0x44, .i = .none }, .{ .n = "f32x4.le", .s = 0x45, .i = .none }, .{ .n = "f32x4.ge", .s = 0x46, .i = .none },
        .{ .n = "f64x2.eq", .s = 0x47, .i = .none }, .{ .n = "f64x2.ne", .s = 0x48, .i = .none }, .{ .n = "f64x2.lt", .s = 0x49, .i = .none }, .{ .n = "f64x2.gt", .s = 0x4a, .i = .none }, .{ .n = "f64x2.le", .s = 0x4b, .i = .none }, .{ .n = "f64x2.ge", .s = 0x4c, .i = .none },
        .{ .n = "v128.not", .s = 0x4d, .i = .none }, .{ .n = "v128.and", .s = 0x4e, .i = .none }, .{ .n = "v128.andnot", .s = 0x4f, .i = .none }, .{ .n = "v128.or", .s = 0x50, .i = .none }, .{ .n = "v128.xor", .s = 0x51, .i = .none }, .{ .n = "v128.bitselect", .s = 0x52, .i = .none }, .{ .n = "v128.any_true", .s = 0x53, .i = .none },
        .{ .n = "i8x16.abs", .s = 0x60, .i = .none }, .{ .n = "i8x16.neg", .s = 0x61, .i = .none }, .{ .n = "i8x16.popcnt", .s = 0x62, .i = .none }, .{ .n = "i8x16.all_true", .s = 0x63, .i = .none }, .{ .n = "i8x16.bitmask", .s = 0x64, .i = .none }, .{ .n = "i8x16.narrow_i16x8_s", .s = 0x65, .i = .none }, .{ .n = "i8x16.narrow_i16x8_u", .s = 0x66, .i = .none }, .{ .n = "i8x16.shl", .s = 0x6b, .i = .none }, .{ .n = "i8x16.shr_s", .s = 0x6c, .i = .none }, .{ .n = "i8x16.shr_u", .s = 0x6d, .i = .none }, .{ .n = "i8x16.add", .s = 0x6e, .i = .none }, .{ .n = "i8x16.add_sat_s", .s = 0x6f, .i = .none }, .{ .n = "i8x16.add_sat_u", .s = 0x70, .i = .none }, .{ .n = "i8x16.sub", .s = 0x71, .i = .none }, .{ .n = "i8x16.sub_sat_s", .s = 0x72, .i = .none }, .{ .n = "i8x16.sub_sat_u", .s = 0x73, .i = .none }, .{ .n = "i8x16.min_s", .s = 0x76, .i = .none }, .{ .n = "i8x16.min_u", .s = 0x77, .i = .none }, .{ .n = "i8x16.max_s", .s = 0x78, .i = .none }, .{ .n = "i8x16.max_u", .s = 0x79, .i = .none }, .{ .n = "i8x16.avgr_u", .s = 0x7b, .i = .none },
        .{ .n = "i16x8.extadd_pairwise_i8x16_s", .s = 0x7c, .i = .none }, .{ .n = "i16x8.extadd_pairwise_i8x16_u", .s = 0x7d, .i = .none },
        .{ .n = "i32x4.extadd_pairwise_i16x8_s", .s = 0x7e, .i = .none }, .{ .n = "i32x4.extadd_pairwise_i16x8_u", .s = 0x7f, .i = .none },
        .{ .n = "i16x8.q15mulr_sat_s", .s = 0x82, .i = .none }, .{ .n = "i32x4.dot_i16x8_s", .s = 0xba, .i = .none },
        .{ .n = "i16x8.extmul_low_i8x16_s", .s = 0x9c, .i = .none }, .{ .n = "i16x8.extmul_high_i8x16_s", .s = 0x9d, .i = .none },
        .{ .n = "i16x8.extmul_low_i8x16_u", .s = 0x9e, .i = .none }, .{ .n = "i16x8.extmul_high_i8x16_u", .s = 0x9f, .i = .none },
        .{ .n = "i32x4.extmul_low_i16x8_s", .s = 0xbc, .i = .none }, .{ .n = "i32x4.extmul_high_i16x8_s", .s = 0xbd, .i = .none },
        .{ .n = "i32x4.extmul_low_i16x8_u", .s = 0xbe, .i = .none }, .{ .n = "i32x4.extmul_high_i16x8_u", .s = 0xbf, .i = .none },
        .{ .n = "i64x2.extmul_low_i32x4_s", .s = 0xdc, .i = .none }, .{ .n = "i64x2.extmul_high_i32x4_s", .s = 0xdd, .i = .none },
        .{ .n = "i64x2.extmul_low_i32x4_u", .s = 0xde, .i = .none }, .{ .n = "i64x2.extmul_high_i32x4_u", .s = 0xdf, .i = .none },
        .{ .n = "i64x2.eq", .s = 0xd6, .i = .none }, .{ .n = "i64x2.ne", .s = 0xd7, .i = .none }, .{ .n = "i64x2.lt_s", .s = 0xd8, .i = .none }, .{ .n = "i64x2.gt_s", .s = 0xd9, .i = .none }, .{ .n = "i64x2.le_s", .s = 0xda, .i = .none }, .{ .n = "i64x2.ge_s", .s = 0xdb, .i = .none },
        .{ .n = "i16x8.abs", .s = 0x80, .i = .none }, .{ .n = "i16x8.neg", .s = 0x81, .i = .none }, .{ .n = "i16x8.all_true", .s = 0x83, .i = .none }, .{ .n = "i16x8.bitmask", .s = 0x84, .i = .none }, .{ .n = "i16x8.narrow_i32x4_s", .s = 0x85, .i = .none }, .{ .n = "i16x8.narrow_i32x4_u", .s = 0x86, .i = .none }, .{ .n = "i16x8.extend_low_i8x16_s", .s = 0x87, .i = .none }, .{ .n = "i16x8.extend_high_i8x16_s", .s = 0x88, .i = .none }, .{ .n = "i16x8.extend_low_i8x16_u", .s = 0x89, .i = .none }, .{ .n = "i16x8.extend_high_i8x16_u", .s = 0x8a, .i = .none }, .{ .n = "i16x8.shl", .s = 0x8b, .i = .none }, .{ .n = "i16x8.shr_s", .s = 0x8c, .i = .none }, .{ .n = "i16x8.shr_u", .s = 0x8d, .i = .none }, .{ .n = "i16x8.add", .s = 0x8e, .i = .none }, .{ .n = "i16x8.add_sat_s", .s = 0x8f, .i = .none }, .{ .n = "i16x8.add_sat_u", .s = 0x90, .i = .none }, .{ .n = "i16x8.sub", .s = 0x91, .i = .none }, .{ .n = "i16x8.sub_sat_s", .s = 0x92, .i = .none }, .{ .n = "i16x8.sub_sat_u", .s = 0x93, .i = .none }, .{ .n = "i16x8.mul", .s = 0x95, .i = .none }, .{ .n = "i16x8.min_s", .s = 0x96, .i = .none }, .{ .n = "i16x8.min_u", .s = 0x97, .i = .none }, .{ .n = "i16x8.max_s", .s = 0x98, .i = .none }, .{ .n = "i16x8.max_u", .s = 0x99, .i = .none }, .{ .n = "i16x8.avgr_u", .s = 0x9b, .i = .none },
        .{ .n = "i32x4.abs", .s = 0xa0, .i = .none }, .{ .n = "i32x4.neg", .s = 0xa1, .i = .none }, .{ .n = "i32x4.all_true", .s = 0xa3, .i = .none }, .{ .n = "i32x4.bitmask", .s = 0xa4, .i = .none }, .{ .n = "i32x4.extend_low_i16x8_s", .s = 0xa7, .i = .none }, .{ .n = "i32x4.extend_high_i16x8_s", .s = 0xa8, .i = .none }, .{ .n = "i32x4.extend_low_i16x8_u", .s = 0xa9, .i = .none }, .{ .n = "i32x4.extend_high_i16x8_u", .s = 0xaa, .i = .none }, .{ .n = "i32x4.shl", .s = 0xab, .i = .none }, .{ .n = "i32x4.shr_s", .s = 0xac, .i = .none }, .{ .n = "i32x4.shr_u", .s = 0xad, .i = .none }, .{ .n = "i32x4.add", .s = 0xae, .i = .none }, .{ .n = "i32x4.sub", .s = 0xb1, .i = .none }, .{ .n = "i32x4.mul", .s = 0xb5, .i = .none }, .{ .n = "i32x4.min_s", .s = 0xb6, .i = .none }, .{ .n = "i32x4.min_u", .s = 0xb7, .i = .none }, .{ .n = "i32x4.max_s", .s = 0xb8, .i = .none }, .{ .n = "i32x4.max_u", .s = 0xb9, .i = .none },
        .{ .n = "i64x2.abs", .s = 0xc0, .i = .none }, .{ .n = "i64x2.neg", .s = 0xc1, .i = .none }, .{ .n = "i64x2.all_true", .s = 0xc3, .i = .none }, .{ .n = "i64x2.bitmask", .s = 0xc4, .i = .none }, .{ .n = "i64x2.extend_low_i32x4_s", .s = 0xc7, .i = .none }, .{ .n = "i64x2.extend_high_i32x4_s", .s = 0xc8, .i = .none }, .{ .n = "i64x2.extend_low_i32x4_u", .s = 0xc9, .i = .none }, .{ .n = "i64x2.extend_high_i32x4_u", .s = 0xca, .i = .none }, .{ .n = "i64x2.shl", .s = 0xcb, .i = .none }, .{ .n = "i64x2.shr_s", .s = 0xcc, .i = .none }, .{ .n = "i64x2.shr_u", .s = 0xcd, .i = .none }, .{ .n = "i64x2.add", .s = 0xce, .i = .none }, .{ .n = "i64x2.sub", .s = 0xd1, .i = .none }, .{ .n = "i64x2.mul", .s = 0xd5, .i = .none },
        .{ .n = "f32x4.ceil", .s = 0x67, .i = .none }, .{ .n = "f32x4.floor", .s = 0x68, .i = .none }, .{ .n = "f32x4.trunc", .s = 0x69, .i = .none }, .{ .n = "f32x4.nearest", .s = 0x6a, .i = .none }, .{ .n = "f32x4.abs", .s = 0xe0, .i = .none }, .{ .n = "f32x4.neg", .s = 0xe1, .i = .none }, .{ .n = "f32x4.sqrt", .s = 0xe3, .i = .none }, .{ .n = "f32x4.add", .s = 0xe4, .i = .none }, .{ .n = "f32x4.sub", .s = 0xe5, .i = .none }, .{ .n = "f32x4.mul", .s = 0xe6, .i = .none }, .{ .n = "f32x4.div", .s = 0xe7, .i = .none }, .{ .n = "f32x4.min", .s = 0xe8, .i = .none }, .{ .n = "f32x4.max", .s = 0xe9, .i = .none }, .{ .n = "f32x4.pmin", .s = 0xea, .i = .none }, .{ .n = "f32x4.pmax", .s = 0xeb, .i = .none }, .{ .n = "f32x4.convert_i32x4_s", .s = 0xfa, .i = .none }, .{ .n = "f32x4.convert_i32x4_u", .s = 0xfb, .i = .none }, .{ .n = "f32x4.demote_f64x2_zero", .s = 0x5e, .i = .none },
        .{ .n = "f64x2.ceil", .s = 0x74, .i = .none }, .{ .n = "f64x2.floor", .s = 0x75, .i = .none }, .{ .n = "f64x2.trunc", .s = 0x7a, .i = .none }, .{ .n = "f64x2.nearest", .s = 0x94, .i = .none }, .{ .n = "f64x2.abs", .s = 0xec, .i = .none }, .{ .n = "f64x2.neg", .s = 0xed, .i = .none }, .{ .n = "f64x2.sqrt", .s = 0xef, .i = .none }, .{ .n = "f64x2.add", .s = 0xf0, .i = .none }, .{ .n = "f64x2.sub", .s = 0xf1, .i = .none }, .{ .n = "f64x2.mul", .s = 0xf2, .i = .none }, .{ .n = "f64x2.div", .s = 0xf3, .i = .none }, .{ .n = "f64x2.min", .s = 0xf4, .i = .none }, .{ .n = "f64x2.max", .s = 0xf5, .i = .none }, .{ .n = "f64x2.pmin", .s = 0xf6, .i = .none }, .{ .n = "f64x2.pmax", .s = 0xf7, .i = .none }, .{ .n = "f64x2.promote_low_f32x4", .s = 0x5f, .i = .none }, .{ .n = "f64x2.convert_low_i32x4_s", .s = 0xfe, .i = .none }, .{ .n = "f64x2.convert_low_i32x4_u", .s = 0xff, .i = .none },
        .{ .n = "i32x4.trunc_sat_f32x4_s", .s = 0xf8, .i = .none }, .{ .n = "i32x4.trunc_sat_f32x4_u", .s = 0xf9, .i = .none }, .{ .n = "i32x4.trunc_sat_f64x2_s_zero", .s = 0xfc, .i = .none }, .{ .n = "i32x4.trunc_sat_f64x2_u_zero", .s = 0xfd, .i = .none },
        // relaxed SIMD (sub-opcodes >= 0x100)
        .{ .n = "i8x16.relaxed_swizzle", .s = 0x100, .i = .none },
        .{ .n = "i32x4.relaxed_trunc_f32x4_s", .s = 0x101, .i = .none }, .{ .n = "i32x4.relaxed_trunc_f32x4_u", .s = 0x102, .i = .none },
        .{ .n = "i32x4.relaxed_trunc_f64x2_s_zero", .s = 0x103, .i = .none }, .{ .n = "i32x4.relaxed_trunc_f64x2_u_zero", .s = 0x104, .i = .none },
        .{ .n = "f32x4.relaxed_madd", .s = 0x105, .i = .none }, .{ .n = "f32x4.relaxed_nmadd", .s = 0x106, .i = .none },
        .{ .n = "f64x2.relaxed_madd", .s = 0x107, .i = .none }, .{ .n = "f64x2.relaxed_nmadd", .s = 0x108, .i = .none },
        .{ .n = "i8x16.relaxed_laneselect", .s = 0x109, .i = .none }, .{ .n = "i16x8.relaxed_laneselect", .s = 0x10a, .i = .none },
        .{ .n = "i32x4.relaxed_laneselect", .s = 0x10b, .i = .none }, .{ .n = "i64x2.relaxed_laneselect", .s = 0x10c, .i = .none },
        .{ .n = "f32x4.relaxed_min", .s = 0x10d, .i = .none }, .{ .n = "f32x4.relaxed_max", .s = 0x10e, .i = .none },
        .{ .n = "f64x2.relaxed_min", .s = 0x10f, .i = .none }, .{ .n = "f64x2.relaxed_max", .s = 0x110, .i = .none },
        .{ .n = "i16x8.relaxed_q15mulr_s", .s = 0x111, .i = .none },
        .{ .n = "i16x8.relaxed_dot_i8x16_i7x16_s", .s = 0x112, .i = .none },
        .{ .n = "i32x4.relaxed_dot_i8x16_i7x16_add_s", .s = 0x113, .i = .none },
    };
    for (tbl) |e| if (std.mem.eql(u8, e.n, name)) return .{ .sub = e.s, .imm = e.i };
    return null;
}

/// The natural (maximum-allowed) alignment, as a log2, for a SIMD memory op —
/// used as the `align=` default. Wrong here means the validator rejects an
/// omitted-align load8_splat/load_lane as over-aligned.
/// Emit a SIMD op: parse its immediate from `items[start..]`, emit operand
/// sub-exprs (folded form only), then `0xFD sub imm`. Returns the next index.
fn emitSimd(ctx: *Ctx, sd: SimdOp, items: []const Sexpr, start: usize, is_folded: bool) Error!usize {
    var j = start;
    var lane: u8 = 0;
    var cbytes: [16]u8 = @splat(0);
    var align_log2: u32 = opcode.simdNaturalAlignLog2(sd.sub);
    var offset: u64 = 0;
    var mem_idx: u32 = 0;
    switch (sd.imm) {
        .none => {},
        .lane => {
            if (j >= items.len) return error.BadImmediate;
            lane = try simdLaneByte(items[j]);
            j += 1;
        },
        .shuffle => for (0..16) |k| {
            if (j >= items.len) return error.BadImmediate;
            cbytes[k] = std.math.cast(u8, @as(u32, @bitCast(@as(i32, @truncate(try parseWatI32(items[j])))))) orelse return error.BadImmediate;
            j += 1;
        },
        .const_ => j = try parseV128Const(items, j, &cbytes),
        .mem, .mem_lane => {
            // The leading atoms are `memidx? offset=? align=?` and — for
            // load/store_lane — a trailing `laneidx`. memidx and laneidx are both
            // bare numbers, so collect the whole atom run first: the last atom is
            // the lane (mem_lane), and a plain non-`offset=`/`align=` atom is the
            // explicit memory index (multi-memory), which must precede the memarg.
            var atoms: [8]Sexpr = undefined;
            var na: usize = 0;
            // Collect ONLY memarg atoms (`offset=`/`align=`) and index-like atoms
            // (the memidx and, for lane ops, the laneidx). Stop at anything else:
            // in FLAT form `items` is the whole sibling instruction sequence, so a
            // following mnemonic (`drop`, `i32.const`) is not index-like and must
            // NOT be swallowed as a memidx/lane. Mirrors the scalar `.mem` flat loop.
            while (j < items.len) : (j += 1) {
                const atom = items[j].asAtom() orelse break;
                const is_memarg = std.mem.startsWith(u8, atom, "offset=") or std.mem.startsWith(u8, atom, "align=");
                if (!is_memarg and !isIndexAtom(items[j])) break;
                if (na >= atoms.len) return error.BadImmediate;
                atoms[na] = items[j];
                na += 1;
            }
            var end = na;
            if (sd.imm == .mem_lane) { // the last atom is the lane index
                if (na == 0) return error.BadImmediate;
                end -= 1;
                lane = try simdLaneByte(atoms[end]);
            }
            for (atoms[0..end], 0..) |atom_s, k| {
                const atom = atom_s.asAtom().?;
                if (std.mem.startsWith(u8, atom, "offset=")) {
                    offset = std.fmt.parseInt(u64, atom[7..], 0) catch return error.BadImmediate;
                } else if (std.mem.startsWith(u8, atom, "align=")) {
                    const by = std.fmt.parseInt(u32, atom[6..], 0) catch return error.BadImmediate;
                    if (by == 0 or (by & (by - 1)) != 0) return error.BadImmediate;
                    align_log2 = @ctz(by);
                } else if (k == 0) { // memidx precedes offset/align in the grammar
                    mem_idx = try resolveByName(ctx.mem_names, atom_s);
                } else return error.BadImmediate;
            }
        },
    }
    if (is_folded) while (j < items.len) {
        j = try emitOne(ctx, items, j);
    };
    try ctx.out.append(ctx.a, 0xfd);
    try uleb(ctx.a, ctx.out, sd.sub);
    switch (sd.imm) {
        .none => {},
        .lane => try ctx.out.append(ctx.a, lane),
        .shuffle, .const_ => try ctx.out.appendSlice(ctx.a, &cbytes),
        .mem => try emitMemArgBytes(ctx, align_log2, mem_idx, offset),
        .mem_lane => {
            try emitMemArgBytes(ctx, align_log2, mem_idx, offset);
            try ctx.out.append(ctx.a, lane);
        },
    }
    return j;
}

/// Parse a SIMD lane / shuffle index atom into a byte (the decoder range-checks
/// it against the op's lane count). `(i32x4.extract_lane 999)` -> `BadImmediate`
/// rather than an `@intCast(u32->u8)` overflow (UB in ReleaseFast).
fn simdLaneByte(s: Sexpr) Error!u8 {
    return std.math.cast(u8, @as(u32, @bitCast(@as(i32, @truncate(try parseWatI32(s)))))) orelse error.BadImmediate;
}

/// Map an atomic (`0xFE`) mnemonic to its sub-opcode, or null. The rmw/cmpxchg
/// families are laid out in groups of 7 from 0x1e (add), then sub/and/or/xor/
/// xchg/cmpxchg, each `[i32.full, i64.full, i32.8, i32.16, i64.8, i64.16,
/// i64.32]`.
fn lookupAtomic(name: []const u8) ?u32 {
    const E = struct { n: []const u8, s: u32 };
    const tbl = [_]E{
        .{ .n = "memory.atomic.notify", .s = 0x00 }, .{ .n = "memory.atomic.wait32", .s = 0x01 },
        .{ .n = "memory.atomic.wait64", .s = 0x02 }, .{ .n = "atomic.fence", .s = 0x03 },
        // loads
        .{ .n = "i32.atomic.load", .s = 0x10 },      .{ .n = "i64.atomic.load", .s = 0x11 },
        .{ .n = "i32.atomic.load8_u", .s = 0x12 },   .{ .n = "i32.atomic.load16_u", .s = 0x13 },
        .{ .n = "i64.atomic.load8_u", .s = 0x14 },   .{ .n = "i64.atomic.load16_u", .s = 0x15 },
        .{ .n = "i64.atomic.load32_u", .s = 0x16 },
        // stores
        .{ .n = "i32.atomic.store", .s = 0x17 },     .{ .n = "i64.atomic.store", .s = 0x18 },
        .{ .n = "i32.atomic.store8", .s = 0x19 },    .{ .n = "i32.atomic.store16", .s = 0x1a },
        .{ .n = "i64.atomic.store8", .s = 0x1b },    .{ .n = "i64.atomic.store16", .s = 0x1c },
        .{ .n = "i64.atomic.store32", .s = 0x1d },
        // rmw add (0x1e), sub (0x25), and (0x2c), or (0x33), xor (0x3a), xchg (0x41)
        .{ .n = "i32.atomic.rmw.add", .s = 0x1e },      .{ .n = "i64.atomic.rmw.add", .s = 0x1f },
        .{ .n = "i32.atomic.rmw8.add_u", .s = 0x20 },   .{ .n = "i32.atomic.rmw16.add_u", .s = 0x21 },
        .{ .n = "i64.atomic.rmw8.add_u", .s = 0x22 },   .{ .n = "i64.atomic.rmw16.add_u", .s = 0x23 },
        .{ .n = "i64.atomic.rmw32.add_u", .s = 0x24 },
        .{ .n = "i32.atomic.rmw.sub", .s = 0x25 },      .{ .n = "i64.atomic.rmw.sub", .s = 0x26 },
        .{ .n = "i32.atomic.rmw8.sub_u", .s = 0x27 },   .{ .n = "i32.atomic.rmw16.sub_u", .s = 0x28 },
        .{ .n = "i64.atomic.rmw8.sub_u", .s = 0x29 },   .{ .n = "i64.atomic.rmw16.sub_u", .s = 0x2a },
        .{ .n = "i64.atomic.rmw32.sub_u", .s = 0x2b },
        .{ .n = "i32.atomic.rmw.and", .s = 0x2c },      .{ .n = "i64.atomic.rmw.and", .s = 0x2d },
        .{ .n = "i32.atomic.rmw8.and_u", .s = 0x2e },   .{ .n = "i32.atomic.rmw16.and_u", .s = 0x2f },
        .{ .n = "i64.atomic.rmw8.and_u", .s = 0x30 },   .{ .n = "i64.atomic.rmw16.and_u", .s = 0x31 },
        .{ .n = "i64.atomic.rmw32.and_u", .s = 0x32 },
        .{ .n = "i32.atomic.rmw.or", .s = 0x33 },       .{ .n = "i64.atomic.rmw.or", .s = 0x34 },
        .{ .n = "i32.atomic.rmw8.or_u", .s = 0x35 },    .{ .n = "i32.atomic.rmw16.or_u", .s = 0x36 },
        .{ .n = "i64.atomic.rmw8.or_u", .s = 0x37 },    .{ .n = "i64.atomic.rmw16.or_u", .s = 0x38 },
        .{ .n = "i64.atomic.rmw32.or_u", .s = 0x39 },
        .{ .n = "i32.atomic.rmw.xor", .s = 0x3a },      .{ .n = "i64.atomic.rmw.xor", .s = 0x3b },
        .{ .n = "i32.atomic.rmw8.xor_u", .s = 0x3c },   .{ .n = "i32.atomic.rmw16.xor_u", .s = 0x3d },
        .{ .n = "i64.atomic.rmw8.xor_u", .s = 0x3e },   .{ .n = "i64.atomic.rmw16.xor_u", .s = 0x3f },
        .{ .n = "i64.atomic.rmw32.xor_u", .s = 0x40 },
        .{ .n = "i32.atomic.rmw.xchg", .s = 0x41 },     .{ .n = "i64.atomic.rmw.xchg", .s = 0x42 },
        .{ .n = "i32.atomic.rmw8.xchg_u", .s = 0x43 },  .{ .n = "i32.atomic.rmw16.xchg_u", .s = 0x44 },
        .{ .n = "i64.atomic.rmw8.xchg_u", .s = 0x45 },  .{ .n = "i64.atomic.rmw16.xchg_u", .s = 0x46 },
        .{ .n = "i64.atomic.rmw32.xchg_u", .s = 0x47 },
        // cmpxchg (0x48)
        .{ .n = "i32.atomic.rmw.cmpxchg", .s = 0x48 },     .{ .n = "i64.atomic.rmw.cmpxchg", .s = 0x49 },
        .{ .n = "i32.atomic.rmw8.cmpxchg_u", .s = 0x4a },  .{ .n = "i32.atomic.rmw16.cmpxchg_u", .s = 0x4b },
        .{ .n = "i64.atomic.rmw8.cmpxchg_u", .s = 0x4c },  .{ .n = "i64.atomic.rmw16.cmpxchg_u", .s = 0x4d },
        .{ .n = "i64.atomic.rmw32.cmpxchg_u", .s = 0x4e },
    };
    inline for (tbl) |e| if (std.mem.eql(u8, name, e.n)) return e.s;
    return null;
}

/// Emit a `0xFE` atomic op. `atomic.fence` (0x03) takes a reserved `0x00`;
/// every other op takes a memarg (optional leading memory index, `offset=`,
/// `align=`; the default alignment is the required natural one). `is_folded`
/// emits the operand sub-expressions first.
fn emitAtomic(ctx: *Ctx, sub: u32, items: []const Sexpr, start: usize, is_folded: bool) Error!usize {
    var j = start;
    if (sub == 0x03) { // atomic.fence: reserved byte, no operands
        try ctx.out.append(ctx.a, 0xfe);
        try uleb(ctx.a, ctx.out, sub);
        try ctx.out.append(ctx.a, 0x00);
        return j;
    }
    var align_log2: u32 = opcode.atomicNaturalAlignLog2(sub);
    var offset: u64 = 0;
    var mem_idx: u32 = 0;
    while (j < items.len) {
        const atom = items[j].asAtom() orelse break;
        if (std.mem.startsWith(u8, atom, "offset=")) {
            offset = std.fmt.parseInt(u64, atom[7..], 0) catch return error.BadImmediate;
        } else if (std.mem.startsWith(u8, atom, "align=")) {
            const by = std.fmt.parseInt(u32, atom[6..], 0) catch return error.BadImmediate;
            if (by == 0 or (by & (by - 1)) != 0) return error.BadImmediate;
            align_log2 = @ctz(by);
        } else if (isIndexAtom(items[j])) {
            mem_idx = try resolveByName(ctx.mem_names, items[j]);
        } else break;
        j += 1;
    }
    if (is_folded) while (j < items.len) {
        j = try emitOne(ctx, items, j);
    };
    try ctx.out.append(ctx.a, 0xfe);
    try uleb(ctx.a, ctx.out, sub);
    if (mem_idx != 0) { // multi-memory: bit 6 flags an explicit index
        try uleb(ctx.a, ctx.out, align_log2 | 0x40);
        try uleb(ctx.a, ctx.out, mem_idx);
    } else {
        try uleb(ctx.a, ctx.out, align_log2);
    }
    try uleb(ctx.a, ctx.out, offset);
    return j;
}

/// Parse a `v128.const <shape> <values…>` immediate into 16 little-endian bytes.
fn parseV128Const(items: []const Sexpr, start: usize, out: *[16]u8) Error!usize {
    var j = start;
    if (j >= items.len) return error.BadImmediate;
    const shape = items[j].asAtom() orelse return error.BadImmediate;
    j += 1;
    // Number of lane values that must follow the shape atom.
    const count: usize = if (std.mem.eql(u8, shape, "i8x16")) 16 else if (std.mem.eql(u8, shape, "i16x8") or std.mem.eql(u8, shape, "f32x4") or std.mem.eql(u8, shape, "i32x4")) (if (std.mem.eql(u8, shape, "i16x8")) 8 else 4) else if (std.mem.eql(u8, shape, "i64x2") or std.mem.eql(u8, shape, "f64x2")) 2 else return error.BadImmediate;
    if (j + count > items.len) return error.BadImmediate;
    if (std.mem.eql(u8, shape, "i8x16")) {
        for (0..16) |k| {
            out[k] = @intCast(@as(u32, @bitCast(@as(i32, @truncate(try parseWatI32(items[j]))))) & 0xff);
            j += 1;
        }
    } else if (std.mem.eql(u8, shape, "i16x8")) {
        for (0..8) |k| {
            std.mem.writeInt(u16, out[k * 2 ..][0..2], @truncate(@as(u64, @bitCast(try parseWatI32(items[j])))), .little);
            j += 1;
        }
    } else if (std.mem.eql(u8, shape, "i32x4")) {
        for (0..4) |k| {
            std.mem.writeInt(u32, out[k * 4 ..][0..4], @truncate(@as(u64, @bitCast(try parseWatI32(items[j])))), .little);
            j += 1;
        }
    } else if (std.mem.eql(u8, shape, "i64x2")) {
        for (0..2) |k| {
            std.mem.writeInt(u64, out[k * 8 ..][0..8], @bitCast(try parseWatI64(items[j])), .little);
            j += 1;
        }
    } else if (std.mem.eql(u8, shape, "f32x4")) {
        for (0..4) |k| {
            const bits = floatLitBits(u32, f32, items[j].asAtom() orelse return error.BadImmediate) orelse return error.BadImmediate;
            std.mem.writeInt(u32, out[k * 4 ..][0..4], bits, .little);
            j += 1;
        }
    } else {
        for (0..2) |k| {
            const bits = floatLitBits(u64, f64, items[j].asAtom() orelse return error.BadImmediate) orelse return error.BadImmediate;
            std.mem.writeInt(u64, out[k * 8 ..][0..8], bits, .little);
            j += 1;
        }
    }
    return j;
}

fn lookupOp(name: []const u8) ?Op {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '.') '_' else c;
    return std.meta.stringToEnum(Op, buf[0..name.len]);
}

fn resolveLocal(ctx: *Ctx, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        for (ctx.local_names, 0..) |nm, i| {
            if (nm != null and std.mem.eql(u8, nm.?, atom)) return @intCast(i);
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn resolveFunc(ctx: *Ctx, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') return resolveByName(ctx.func_names, s);
    return parseIndex(s);
}

fn resolveByName(names: []const ?[]const u8, s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    if (atom.len != 0 and atom[0] == '$') {
        for (names, 0..) |nm, i| {
            if (nm != null and std.mem.eql(u8, nm.?, atom)) return @intCast(i);
        }
        return error.UnknownIdentifier;
    }
    return parseIndex(s);
}

fn parseIndex(s: Sexpr) Error!u32 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    return std.fmt.parseInt(u32, atom, 0) catch error.BadImmediate;
}

/// Parse an unsigned integer that may exceed u32 — a memory64 page limit
/// (`_` digit separators allowed, e.g. `0x1_0000_0000_0000`).
fn parseU64(s: Sexpr) Error!u64 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    return std.fmt.parseInt(u64, atom, 0) catch error.BadImmediate;
}

const MemLimits = struct { min: u64, max: ?u64 = null, shared: bool = false, is64: bool = false };

/// Parse a memory `memtype` tail from `items[mi.*..]`: an optional index type
/// (`i64`/`i32`) — which canonically sits HERE, after any inline export/import
/// clauses — then `min max? shared?`. `is64_seen` carries an index type already
/// consumed right after the name (the common non-canonical position wabt/binaryen
/// emit); either position is accepted, neither required. Advances `mi`. One home
/// for the parse the three memory sites (inline defined / inline import /
/// top-level `(import … (memory …))`) used to each copy.
/// Reject anything left over in a `(memory …)` field after its limits.
///
/// `parseMemLimits` stops at the first item that is not a number / `shared`, and
/// the caller used to just walk away — so every trailing form was **silently
/// dropped**. `(memory 0 (pagesize 3))` therefore assembled into a plain 64 KiB-
/// page memory: the module built, ran, and disagreed with its own source. That
/// is 18 of `custom-page-sizes-invalid.wast`'s assertions, and the *reason* the
/// `memory.grow` in `custom-page-sizes.wast` answers −1 — the memory was never
/// the one the text asked for. A trailing ATOM already failed (`parseU64` chokes
/// on it); only lists slipped through, which is why this went unnoticed.
///
/// `pagesize` is named separately because it is real syntax from a real proposal
/// we do not implement, not a typo — see `error.UnsupportedProposal`.
fn checkMemTail(items: []const Sexpr, mi: usize) Error!void {
    if (mi >= items.len) return;
    if (items[mi].asList()) |l| if (l.len != 0 and eqAtom(l[0], "pagesize"))
        return error.UnsupportedProposal;
    return error.BadModuleField;
}

fn parseMemLimits(items: []const Sexpr, mi: *usize, is64_seen: bool, type_seen: bool) Error!MemLimits {
    var is64 = is64_seen;
    // Consume the index type here only if one wasn't already taken after the name
    // — otherwise a doubled `(memory i64 i64 1)` would be silently accepted (the
    // leftover `i64` then fails `parseU64` as a non-number, which is the rejection).
    if (!type_seen) {
        if (mi.* < items.len and eqAtom(items[mi.*], "i64")) {
            is64 = true;
            mi.* += 1;
        } else if (mi.* < items.len and eqAtom(items[mi.*], "i32")) {
            mi.* += 1;
        }
    }
    const min = try parseU64(try nth(items, mi.*));
    mi.* += 1;
    var max: ?u64 = null;
    if (mi.* < items.len and items[mi.*].asAtom() != null and !eqAtom(items[mi.*], "shared")) {
        max = try parseU64(items[mi.*]);
        mi.* += 1;
    }
    const shared = mi.* < items.len and eqAtom(items[mi.*], "shared");
    if (shared) mi.* += 1;
    return .{ .min = min, .max = max, .shared = shared, .is64 = is64 };
}

fn parseWatI32(s: Sexpr) Error!i64 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    const v = std.fmt.parseInt(i64, atom, 0) catch (std.fmt.parseInt(u32, atom, 0) catch return error.BadImmediate);
    return @as(i32, @truncate(v)); // sign-extended back to i64 for SLEB
}

fn parseWatI64(s: Sexpr) Error!i64 {
    const atom = s.asAtom() orelse return error.BadImmediate;
    return std.fmt.parseInt(i64, atom, 0) catch {
        const u = std.fmt.parseInt(u64, atom, 0) catch return error.BadImmediate;
        return @bitCast(u);
    };
}

fn floatBits(ctx: *Ctx, comptime U: type, s: Sexpr) Error!void {
    const atom = s.asAtom() orelse return error.BadImmediate;
    const F = if (U == u32) f32 else f64;
    const bits = floatLitBits(U, F, atom) orelse return error.BadImmediate;
    var b: [@sizeOf(U)]u8 = undefined;
    std.mem.writeInt(U, &b, bits, .little);
    try ctx.out.appendSlice(ctx.a, &b);
}

/// Parse a WAT float literal to its bit pattern. `std.fmt.parseFloat` handles
/// ordinary values plus plain `inf`/`nan`; this adds the wasm `nan:canonical` /
/// `nan:arithmetic` / `nan:0x<payload>` forms. Returns null on a malformed literal.
fn floatLitBits(comptime U: type, comptime F: type, lit: []const u8) ?U {
    if (std.mem.indexOfScalar(u8, lit, ':')) |c| {
        const canonical: U = if (F == f32) 0x7fc00000 else 0x7ff8000000000000;
        const sign_bit: U = @as(U, 1) << (@bitSizeOf(F) - 1);
        const mant_mask: U = (@as(U, 1) << std.math.floatMantissaBits(F)) - 1;
        var bits: U = canonical;
        const tail = lit[c + 1 ..];
        if (!std.mem.eql(u8, tail, "canonical") and !std.mem.eql(u8, tail, "arithmetic")) {
            const payload = std.fmt.parseInt(U, tail, 0) catch return null;
            bits = (canonical & ~mant_mask) | (payload & mant_mask);
        }
        if (lit.len != 0 and lit[0] == '-') bits |= sign_bit;
        return bits;
    }
    const f = parseFloatLit(F, lit) orelse return null;
    return @bitCast(f);
}

/// Parse a WAT numeric float literal to `F`, **correctly rounded**.
///
/// Decimal literals go to `std.fmt.parseFloat`, but hexadecimal ones
/// (`0x1.abcp+3`, and the exponent-less `0xABC` form the text format also
/// allows) are parsed here, because `std.fmt.parseFloat` **truncates** a hex
/// mantissa longer than ~17 hex digits instead of rounding it:
///
///     0x0123456789ABCDEFa       -> 0x43b23456789abcdf   (correct)
///     0x0123456789ABCDEFabcdef  -> 0x44f23456789abcde   (should be ...cdf)
///
/// That is a *wrong value*, not a rejected one: the assembler silently emitted a
/// constant one ULP low, so the same number written in decimal and in hex
/// compiled to different modules. Found via the spec suite's
/// `simd_f64x2_rounding.wast`, whose literals are long enough to cross the
/// threshold. (Third upstream Zig issue this project works around; unlike the
/// other two it is cheap to route around, so we do.)
///
/// `wast.zig` shares this — one authority for float literals across the
/// assembler and the `.wast` runner, so an expectation and the module it checks
/// can never disagree about what a literal means.
///
/// Returns null on a malformed literal. `inf`/`nan` are not hex and fall through
/// to std; the wasm-specific `nan:…` spellings are the caller's job.
pub fn parseFloatLit(comptime F: type, lit: []const u8) ?F {
    var s = lit;
    var neg = false;
    if (s.len != 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (!(s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')))
        return std.fmt.parseFloat(F, lit) catch null;
    s = s[2..];

    // Accumulate the hex significand into a u128. Digits beyond its capacity
    // cannot change the rounded result except through the sticky bit, so they
    // are folded into `sticky` rather than dropped silently.
    var mant: u128 = 0;
    var sticky = false;
    var exp: i32 = 0; // binary exponent contributed by digit placement
    var seen_digit = false;
    var seen_dot = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            if (seen_dot) return null;
            seen_dot = true;
            continue;
        }
        if (c == 'p' or c == 'P') break;
        if (c == '_') continue; // the text format permits digit separators
        const d: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        seen_digit = true;
        if (mant >> 124 != 0) {
            if (d != 0) sticky = true;
            if (!seen_dot) exp += 4; // a dropped integer digit still scales the value
        } else {
            mant = (mant << 4) | d;
            if (seen_dot) exp -= 4;
        }
    }
    if (!seen_digit) return null;
    if (i < s.len) { // `p` exponent
        i += 1;
        var pneg = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            pneg = s[i] == '-';
            i += 1;
        }
        if (i >= s.len) return null;
        var pexp: i64 = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '_') continue;
            if (s[i] < '0' or s[i] > '9') return null;
            pexp = pexp * 10 + (s[i] - '0');
            if (pexp > 1 << 30) pexp = 1 << 30; // saturate — it overflows/underflows either way
        }
        exp += @intCast(if (pneg) -pexp else pexp);
    }
    if (mant == 0) return if (neg) -@as(F, 0.0) else @as(F, 0.0);

    // value = mant × 2^exp. Round it, in ONE step, to a multiple of the target's
    // ULP — then `ldexp` only scales an exact integer and never rounds again.
    //
    // The ULP exponent is the coarser of the normalised one (`e - prec + 1`) and
    // the smallest subnormal's (`min_e - prec + 1`). Taking the max is what makes
    // normal, subnormal, and below-the-smallest-subnormal a single path. Rounding
    // in two stages instead — clamping the kept-bit count and letting `ldexp`
    // finish — throws away the sticky bit, so a value just ABOVE half the
    // smallest subnormal flushed to zero instead of rounding up to it.
    const prec: i32 = std.math.floatMantissaBits(F) + 1;
    const msb: i32 = 128 - @as(i32, @clz(mant));
    const e: i32 = exp + msb - 1;
    const ulp_exp: i32 = @max(std.math.floatExponentMin(F) - prec + 1, e - prec + 1);

    var q: u128 = undefined;
    const k: i32 = ulp_exp - exp;
    if (k > 0) {
        // Round to nearest, ties to even. `q` may carry into the next binade
        // (becoming 2^prec); that is exactly representable, so `ldexp` is still
        // exact and the result lands on the right side of the boundary.
        // `k` can exceed the width of `mant` for a value far below the smallest
        // subnormal. A u128 shift is only defined for 0..127, and `@intCast` to
        // the shift type would be out of range — silently wrong in ReleaseFast —
        // so the whole-mantissa-shifted-out case is handled separately.
        if (k > 128) {
            if (mant != 0) sticky = true; // guard bit is past the top: no round-up
            q = 0;
        } else {
            const sh: u7 = @intCast(k - 1); // k-1 is 0..127 here
            const guard = (mant >> sh) & 1;
            if (mant & ((@as(u128, 1) << sh) - 1) != 0) sticky = true;
            q = if (k == 128) 0 else mant >> @intCast(k);
            if (guard != 0 and (sticky or (q & 1) != 0)) q += 1;
        }
    } else {
        q = mant << @intCast(-k);
    }

    const scaled = std.math.ldexp(@as(F, @floatFromInt(q)), ulp_exp);
    return if (neg) -scaled else scaled;
}

test "hex float literals are correctly ROUNDED, not truncated" {
    // The exact case from `simd_f64x2_rounding.wast`: std truncates to ...cde.
    try std.testing.expectEqual(
        @as(u64, 0x44f23456789abcdf),
        @as(u64, @bitCast(parseFloatLit(f64, "0x0123456789ABCDEFabcdef").?)),
    );
    // Short mantissas (where std was already right) must not regress.
    try std.testing.expectEqual(
        @as(u64, 0x43b23456789abcdf),
        @as(u64, @bitCast(parseFloatLit(f64, "0x0123456789ABCDEFa").?)),
    );
    try std.testing.expectEqual(
        @as(u64, 0x44a23456789abcdf),
        @as(u64, @bitCast(parseFloatLit(f64, "0x0123456789ABCDEFp019").?)),
    );
    try std.testing.expectEqual(
        @as(u64, 0x45023456789abcde),
        @as(u64, @bitCast(parseFloatLit(f64, "0x1.23456789abcdep+81").?)),
    );
    // The SAME value in hex and in decimal must compile identically — the
    // property the truncation broke.
    try std.testing.expectEqual(
        @as(u64, @bitCast(parseFloatLit(f64, "1.3754889325393114e+24").?)),
        @as(u64, @bitCast(parseFloatLit(f64, "0x0123456789ABCDEFabcdef").?)),
    );
    try std.testing.expectEqual(@as(f64, 1.0), parseFloatLit(f64, "0x1p+0").?);
    try std.testing.expectEqual(@as(f64, 0.5), parseFloatLit(f64, "0x1p-1").?);
    try std.testing.expectEqual(@as(f64, -2.0), parseFloatLit(f64, "-0x1p+1").?);
    // Boundaries: smallest subnormal, smallest normal, largest finite, overflow.
    try std.testing.expectEqual(@as(u64, 1), @as(u64, @bitCast(parseFloatLit(f64, "0x1p-1074").?)));
    try std.testing.expectEqual(@as(u64, 0x0010000000000000), @as(u64, @bitCast(parseFloatLit(f64, "0x1p-1022").?)));
    try std.testing.expectEqual(@as(u64, 0x7fefffffffffffff), @as(u64, @bitCast(parseFloatLit(f64, "0x1.fffffffffffffp+1023").?)));
    try std.testing.expect(std.math.isInf(parseFloatLit(f64, "0x1p+1024").?));
    try std.testing.expectEqual(@as(f64, 0.0), parseFloatLit(f64, "0x0p+0").?);
    try std.testing.expect(std.math.signbit(parseFloatLit(f64, "-0x0p+0").?));
    // f32 rounds in its own precision.
    try std.testing.expectEqual(@as(u32, 0x3f800000), @as(u32, @bitCast(parseFloatLit(f32, "0x1p+0").?)));
    try std.testing.expectEqual(@as(u32, 0x00000001), @as(u32, @bitCast(parseFloatLit(f32, "0x1p-149").?)));
    // Below the smallest subnormal, rounding must still consider the STICKY bits:
    // just over half a ULP rounds UP, exactly half ties to even (= zero), and
    // just under stays zero. Two-stage rounding got the first of these wrong.
    try std.testing.expectEqual( // spec suite simd_const.wast:825
        @as(u64, 1),
        @as(u64, @bitCast(parseFloatLit(f64, "0x0.000000000000080000000001p-1022").?)),
    );
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(parseFloatLit(f64, "0x1p-1075").?))); // exactly half -> even
    try std.testing.expectEqual(@as(u64, 1), @as(u64, @bitCast(parseFloatLit(f64, "0x1.8p-1075").?))); // 3/4 ULP -> up
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(parseFloatLit(f64, "0x1p-1200").?))); // far below -> 0
    // 0x0.00000500000000001p-126 = just over 2.5 ULP -> 3 ULP (spec expects
    // 0x0.000006p-126, i.e. 6 x 2^-150 = 3 x 2^-149 = bit pattern 3).
    try std.testing.expectEqual(@as(u32, 3), @as(u32, @bitCast(parseFloatLit(f32, "0x0.00000500000000001p-126").?)));
    // Ties-to-even at the smallest subnormal, and the carry-into-next-binade case.
    try std.testing.expectEqual(@as(u64, 2), @as(u64, @bitCast(parseFloatLit(f64, "0x1.8p-1074").?))); // 1.5 ULP -> even = 2
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 2.0))),
        @as(u64, @bitCast(parseFloatLit(f64, "0x1.ffffffffffffffp+0").?)), // rounds up to 2.0
    );
    // Decimal literals still go through std, unchanged.
    try std.testing.expectEqual(@as(f64, 1.5), parseFloatLit(f64, "1.5").?);
    // Malformed input is rejected, not silently accepted.
    try std.testing.expect(parseFloatLit(f64, "0x") == null);
    try std.testing.expect(parseFloatLit(f64, "0x1p") == null);
    try std.testing.expect(parseFloatLit(f64, "0x1.2.3p+0") == null);
    try std.testing.expect(parseFloatLit(f64, "0xzz") == null);
}

// --- Section / LEB helpers -------------------------------------------------

/// Parse an exception tag's type descriptor from `items[start..]` — a `(type $t)`
/// reference or `(param …)* (result …)?` — and resolve it to a signature index.
/// Shared by imported tags (top-level `(import … (tag …))` and inline
/// `(tag (import …) …)`); the defined-tag field inlines the same shape because it
/// also collects inline exports.
fn parseTagType(a: std.mem.Allocator, items: []const Sexpr, start: usize, sigs: *List(Sig), type_names: []const ?[]const u8) Error!u32 {
    var j = start;
    var type_ref: ?u32 = null;
    var params: List(V) = .empty;
    var results: List(V) = .empty;
    while (j < items.len) : (j += 1) {
        const tkw = items[j].keyword() orelse break;
        if (std.mem.eql(u8, tkw, "type")) {
            type_ref = try resolveType(type_names, try nth(try wantList(items[j]), 1));
        } else if (std.mem.eql(u8, tkw, "param")) {
            try parseDecls(a, (try wantList(items[j])), &params, null, type_names);
        } else if (std.mem.eql(u8, tkw, "result")) {
            try parseDecls(a, (try wantList(items[j])), &results, null, type_names);
        } else break;
    }
    return resolveTagSig(a, sigs, type_ref, params.items, results.items);
}

/// Resolve a tag's signature from an optional `(type $t)` reference and inline
/// params/results. When BOTH a type index and inline params/results are given,
/// they must agree (§ typeuse — the inline form is a check); otherwise intern the
/// inline signature. Shared by imported (`parseTagType`) and defined tags.
fn resolveTagSig(a: std.mem.Allocator, sigs: *List(Sig), type_ref: ?u32, params: []const V, results: []const V) Error!u32 {
    if (type_ref) |tr| {
        // Guard the index — a malformed numeric type index is caught downstream at
        // decode/validate; here we only cross-check when both forms are present.
        if ((params.len != 0 or results.len != 0) and tr < sigs.items.len) {
            const sig = sigs.items[tr];
            if (!std.mem.eql(V, sig.params, params) or !std.mem.eql(V, sig.results, results))
                return error.BadModuleField;
        }
        return tr;
    }
    return try internSig(a, sigs, params, results);
}

fn internSig(a: std.mem.Allocator, sigs: *List(Sig), params: []const V, results: []const V) Error!u32 {
    for (sigs.items, 0..) |sig, i| {
        if (sig.gc_placeholder) continue; // a struct/array slot is not a func type
        if (std.mem.eql(V, sig.params, params) and std.mem.eql(V, sig.results, results)) return @intCast(i);
    }
    try sigs.append(a, .{ .params = params, .results = results });
    return @intCast(sigs.items.len - 1);
}

/// Emit one value type. A numeric/abstract type is its single byte; a concrete
/// typed reference `(ref null? $t)` is `0x63`/`0x64` + the type index (`s33`).
fn emitValType(a: std.mem.Allocator, out: *List(u8), v: V) Error!void {
    if (v.isConcrete()) {
        try out.append(a, if (v.isNonNullRef()) 0x64 else 0x63);
        try sleb(a, out, v.concreteIndex());
    } else {
        try out.append(a, @intCast(@intFromEnum(v)));
    }
}

fn valTypeVec(a: std.mem.Allocator, out: *List(u8), vts: []const V) Error!void {
    try uleb(a, out, vts.len);
    for (vts) |v| try emitValType(a, out, v);
}

/// Emit a GC field type: a storage-type byte (packed i8=0x78 / i16=0x77, else
/// the value type) followed by a mutability byte.
fn emitGcField(a: std.mem.Allocator, out: *List(u8), f: GcField) Error!void {
    switch (f.storage) {
        .val => |v| try emitValType(a, out, v),
        .i8 => try out.append(a, 0x78),
        .i16 => try out.append(a, 0x77),
    }
    try out.append(a, if (f.mutable) 0x01 else 0x00);
}

fn nameBytes(a: std.mem.Allocator, out: *List(u8), name: []const u8) Error!void {
    try uleb(a, out, name.len);
    try out.appendSlice(a, name);
}

/// Emit a `limits` (§5.3.7): flag byte (0x01 if a max is present) then min[, max].
fn emitLimits(a: std.mem.Allocator, out: *List(u8), min: u64, max: ?u64, shared: bool, is64: bool) Error!void {
    // Flag bits: 0 = has max, 1 = shared (threads), 2 = i64 index (memory64).
    const flag: u8 = (if (max != null) @as(u8, 0x01) else 0) |
        (if (shared) @as(u8, 0x02) else 0) |
        (if (is64) @as(u8, 0x04) else 0);
    try out.append(a, flag);
    try uleb(a, out, min);
    if (max) |mx| try uleb(a, out, mx);
}

fn emitSection(a: std.mem.Allocator, out: *List(u8), id: u8, payload: []const u8) Error!void {
    try out.append(a, id);
    try uleb(a, out, payload.len);
    try out.appendSlice(a, payload);
}

fn uleb(a: std.mem.Allocator, out: *List(u8), value: u64) Error!void {
    var v: u64 = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try out.append(a, byte);
        if (v == 0) break;
    }
}

fn sleb(a: std.mem.Allocator, out: *List(u8), value: i64) Error!void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7; // arithmetic shift
        const sign = byte & 0x40;
        if ((v == 0 and sign == 0) or (v == -1 and sign != 0)) {
            try out.append(a, byte);
            break;
        }
        byte |= 0x80;
        try out.append(a, byte);
    }
}

// --- Tests -----------------------------------------------------------------

const Module = @import("Module.zig");
const interp = @import("interp.zig");
const validate = @import("validate.zig").validate;

/// Assemble + decode + validate `src`, asserting the module is REJECTED (at any
/// stage). Fails the test only if the module is wrongly accepted.
fn expectInvalid(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = assemble(a, src) catch return; // rejected at assembly is fine
    var m = Module.decode(a, bin) catch return; // rejected at decode is fine
    if (validate(a, &m)) |_| return error.TestExpectedRejection else |_| {}
}

test "validation rejects invalid modules" {
    // Non-constant global init, wrong-typed init, forward global.get.
    try expectInvalid("(module (global i32 (i32.ctz (i32.const 0))))");
    try expectInvalid("(module (global i32 (f32.const 0)))");
    try expectInvalid("(module (global i32 (global.get 0)))");
    // Untyped select on reference operands.
    try expectInvalid("(module (func (param funcref funcref i32) (drop (select (local.get 0) (local.get 1) (local.get 2)))))");
    // call_indirect with no table.
    try expectInvalid("(module (type (func)) (func (call_indirect (type 0) (i32.const 0))))");
    // Over-aligned load (align=2 on load8).
    try expectInvalid("(module (memory 0) (func (drop (i32.load8_u align=2 (i32.const 0)))))");
    // Non-power-of-two / zero alignment (#8) — rejected at assembly.
    try expectInvalid("(module (memory 0) (func (drop (i32.load align=3 (i32.const 0)))))");
    try expectInvalid("(module (memory 0) (func (drop (i32.load align=0 (i32.const 0)))))");
    // Load with no memory at all.
    try expectInvalid("(module (func (drop (i32.load (i32.const 0)))))");
    // ref.is_null on a non-reference operand.
    try expectInvalid("(module (func (drop (ref.is_null (i32.const 0)))))");
}

fn assembleAndRun(src: []const u8, name: []const u8, args: []const interp.Value) !interp.Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a, src);
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    const r = try inst.invoke(name, args);
    return r[0];
}

test "assembler rejects malformed forms without indexing out of bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each of these is shape-malformed: the assembler must return an error, never
    // read `items[N]` past a short form or unwrap a wrong-union `.?` (UB in
    // ReleaseFast). Pre-hardening several of these crashed / read OOB.
    const cases = [_][]const u8{
        "(module (export \"x\"))", // export missing its (kind $id) target
        "(module (export))", // export missing even the name
        "(module (export \"x\" foo))", // target is an atom, not a list
        "(module (import \"m\"))", // import missing name + desc
        "(module (import \"m\" \"n\"))", // import missing the desc form
        "(module (type))", // type missing its body
        "(module (func (type)))", // inline (type) missing the index
        "(module (memory (import \"m\" \"n\")))", // memory import missing min
        "(module (memory))", // memory missing its limits (else-branch index)
        "(module (global ()))", // global's type list is empty
        "(module (elem (table)))", // active elem's (table) missing the index
    };
    for (cases) |src| {
        try std.testing.expectError(error.BadModuleField, assemble(a, src));
    }
    // A folded `(if () ())` with an empty then/else form reports BadImmediate.
    try std.testing.expectError(error.BadImmediate, assemble(a, "(module (func (if () ())))"));
    // A SIMD lane / shuffle index that doesn't fit a byte must error, not
    // `@intCast(u32→u8)`-overflow (UB in ReleaseFast).
    try std.testing.expectError(error.BadImmediate, assemble(a, "(module (func (i32x4.extract_lane 999)))"));
    try std.testing.expectError(error.BadImmediate, assemble(a, "(module (func (i8x16.shuffle 999 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))"));
}

test "parser rejects a deeply-nested paren bomb instead of overflowing the stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendNTimes(a, '(', 5000); // far past the nesting cap
    try std.testing.expectError(error.NestingTooDeep, assemble(a, buf.items));
}

test "assembles and runs a folded add" {
    const v = try assembleAndRun(
        \\(module (func (export "add") (param $x i32) (param $y i32) (result i32)
        \\  (i32.add (local.get $x) (local.get $y))))
    , "add", &.{ interp.i32Value(10), interp.i32Value(20) });
    try std.testing.expectEqual(@as(i32, 30), interp.asI32(v));
}

test "assembles flat instruction form" {
    const v = try assembleAndRun(
        \\(module (func (export "f") (param i32 i32) (result i32)
        \\  local.get 0 local.get 1 i32.mul))
    , "f", &.{ interp.i32Value(6), interp.i32Value(7) });
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(v));
}

test "assembles a nested folded expression with a const" {
    const v = try assembleAndRun(
        \\(module (func (export "g") (param $x i32) (result i32)
        \\  (i32.sub (i32.mul (local.get $x) (i32.const 3)) (i32.const 1))))
    , "g", &.{interp.i32Value(10)});
    try std.testing.expectEqual(@as(i32, 29), interp.asI32(v));
}

test "top-level export and a two-function module" {
    const v = try assembleAndRun(
        \\(module
        \\  (func $dbl (param $x i32) (result i32) (i32.add (local.get $x) (local.get $x)))
        \\  (func $quad (param $x i32) (result i32) (call $dbl (call $dbl (local.get $x))))
        \\  (export "quad" (func $quad)))
    , "quad", &.{interp.i32Value(5)});
    try std.testing.expectEqual(@as(i32, 20), interp.asI32(v));
}

test "assembles SIMD folded splat+add+extract (v128)" {
    const v = try assembleAndRun(
        \\(module (func (export "f") (result i32)
        \\  (i32x4.extract_lane 0
        \\    (i32x4.add (i32x4.splat (i32.const 10)) (i32x4.splat (i32.const 32))))))
    , "f", &.{});
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(v));
}

test "assembles SIMD v128.const with i32x4 shape" {
    const v = try assembleAndRun(
        \\(module (func (export "f") (result i32)
        \\  (i32x4.extract_lane 2 (v128.const i32x4 1 2 3 4))))
    , "f", &.{});
    try std.testing.expectEqual(@as(i32, 3), interp.asI32(v));
}

test "assembles SIMD flat form (v128)" {
    const v = try assembleAndRun(
        \\(module (func (export "f") (result f32)
        \\  v128.const f32x4 1.5 2.5 3.5 4.5
        \\  v128.const f32x4 0.5 0.5 0.5 0.5
        \\  f32x4.add
        \\  f32x4.extract_lane 1))
    , "f", &.{});
    try std.testing.expectEqual(@as(f32, 3.0), interp.asF32(v));
}

test "assembles SIMD v128 load/store (memarg) + shuffle + signed i8x16.const" {
    const store_load = try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32)
        \\  (v128.store offset=16 (i32.const 0) (v128.const i32x4 100 200 300 400))
        \\  (i32x4.extract_lane 1 (v128.load offset=16 align=16 (i32.const 0)))))
    , "f", &.{});
    try std.testing.expectEqual(@as(i32, 200), interp.asI32(store_load));

    const shuffled = try assembleAndRun(
        \\(module (func (export "f") (result i32)
        \\  (i32x4.extract_lane 0
        \\    (i8x16.shuffle 16 17 18 19 0 0 0 0 0 0 0 0 0 0 0 0
        \\      (v128.const i32x4 0 0 0 0) (v128.const i32x4 777 0 0 0)))))
    , "f", &.{});
    try std.testing.expectEqual(@as(i32, 777), interp.asI32(shuffled));

    const neg = try assembleAndRun(
        \\(module (func (export "f") (result i32)
        \\  (i8x16.extract_lane_u 15
        \\    (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 -1))))
    , "f", &.{});
    try std.testing.expectEqual(@as(i32, 255), interp.asI32(neg));
}

test "assembles SIMD extmul / dot / extadd_pairwise / q15mulr / i64x2.eq" {
    // i16x8.extmul_low_i8x16_s: lane0 = 3*4 = 12
    try std.testing.expectEqual(@as(i32, 12), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i16x8.extract_lane_s 0
        \\  (i16x8.extmul_low_i8x16_s
        \\    (v128.const i8x16 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
        \\    (v128.const i8x16 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))))
    , "f", &.{})));
    // i32x4.dot_i16x8_s: lane0 = 1*1 + 2*2 = 5
    try std.testing.expectEqual(@as(i32, 5), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i32x4.extract_lane 0
        \\  (i32x4.dot_i16x8_s (v128.const i16x8 1 2 3 4 5 6 7 8)
        \\                     (v128.const i16x8 1 2 3 4 5 6 7 8)))))
    , "f", &.{})));
    // i16x8.extadd_pairwise_i8x16_s: lane0 = 10 + 20 = 30
    try std.testing.expectEqual(@as(i32, 30), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i16x8.extract_lane_s 0
        \\  (i16x8.extadd_pairwise_i8x16_s
        \\    (v128.const i8x16 10 20 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))))
    , "f", &.{})));
    // i16x8.q15mulr_sat_s: (16384*16384 + 0x4000) >> 15 = 8192
    try std.testing.expectEqual(@as(i32, 8192), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i16x8.extract_lane_s 0
        \\  (i16x8.q15mulr_sat_s (v128.const i16x8 16384 0 0 0 0 0 0 0)
        \\                       (v128.const i16x8 16384 0 0 0 0 0 0 0)))))
    , "f", &.{})));
    // i64x2.eq: equal lanes -> all-ones (-1)
    try std.testing.expectEqual(@as(i64, -1), interp.asI64(try assembleAndRun(
        \\(module (func (export "f") (result i64) (i64x2.extract_lane 0
        \\  (i64x2.eq (v128.const i64x2 42 0) (v128.const i64x2 42 0)))))
    , "f", &.{})));
}

test "assembles SIMD load-splat / load-lane / store-lane / widening + zero load" {
    // v128.load8_splat: broadcast a byte, read a far lane
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32)
        \\  (v128.store (i32.const 0) (v128.const i8x16 0 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0))
        \\  (i8x16.extract_lane_u 3 (v128.load8_splat (i32.const 8)))))
    , "f", &.{})));
    // v128.load32_lane 1: load into lane 1
    try std.testing.expectEqual(@as(i32, 111), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32)
        \\  (v128.store (i32.const 0) (v128.const i32x4 111 222 333 444))
        \\  (i32x4.extract_lane 1 (v128.load32_lane 1 (i32.const 0) (v128.const i32x4 0 0 0 0)))))
    , "f", &.{})));
    // v128.store32_lane 3: store lane 3 to memory, read back
    try std.testing.expectEqual(@as(i32, 8), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32)
        \\  (v128.store32_lane 3 (i32.const 32) (v128.const i32x4 5 6 7 8))
        \\  (i32.load (i32.const 32))))
    , "f", &.{})));
    // v128.load16x4_u: zero-extend a 0xFFFF u16 lane -> 65535
    try std.testing.expectEqual(@as(i32, 65535), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32)
        \\  (v128.store (i32.const 0) (v128.const i16x8 -1 2 3 4 0 0 0 0))
        \\  (i32x4.extract_lane 0 (v128.load16x4_u (i32.const 0)))))
    , "f", &.{})));
    // v128.load32_zero: low lane loaded, high lanes zeroed
    try std.testing.expectEqual(@as(i32, 999), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32)
        \\  (v128.store (i32.const 0) (v128.const i32x4 999 888 777 666))
        \\  (i32x4.extract_lane 0 (v128.load32_zero (i32.const 0)))))
    , "f", &.{})));
}

test "v128 GC field fails loud (no silent slot corruption)" {
    // A struct/array with a v128 field can't fit the flat one-slot-per-field
    // object model; the GC op must trap rather than drop the high 64 bits.
    try std.testing.expectError(error.UnsupportedInstruction, assembleAndRun(
        \\(module (type $s (struct (field (mut v128))))
        \\  (func (export "f") (result i32) (drop (struct.new_default $s)) (i32.const 1)))
    , "f", &.{}));
    try std.testing.expectError(error.UnsupportedInstruction, assembleAndRun(
        \\(module (type $a (array (mut v128)))
        \\  (func (export "f") (result i32) (drop (array.new_default $a (i32.const 3))) (i32.const 1)))
    , "f", &.{}));
}

test "assembles relaxed-SIMD ops (madd / laneselect / swizzle / dot)" {
    // f32x4.relaxed_madd: 2*3 + 4 = 10
    try std.testing.expectEqual(@as(f32, 10), interp.asF32(try assembleAndRun(
        \\(module (func (export "f") (result f32) (f32x4.extract_lane 0
        \\  (f32x4.relaxed_madd (v128.const f32x4 2 0 0 0) (v128.const f32x4 3 0 0 0)
        \\                      (v128.const f32x4 4 0 0 0)))))
    , "f", &.{})));
    // f32x4.relaxed_nmadd: -(2*3) + 10 = 4
    try std.testing.expectEqual(@as(f32, 4), interp.asF32(try assembleAndRun(
        \\(module (func (export "f") (result f32) (f32x4.extract_lane 0
        \\  (f32x4.relaxed_nmadd (v128.const f32x4 2 0 0 0) (v128.const f32x4 3 0 0 0)
        \\                       (v128.const f32x4 10 0 0 0)))))
    , "f", &.{})));
    // i32x4.relaxed_laneselect: all-ones mask picks the first operand (111)
    try std.testing.expectEqual(@as(i32, 111), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i32x4.extract_lane 0
        \\  (i32x4.relaxed_laneselect (v128.const i32x4 111 0 0 0) (v128.const i32x4 222 0 0 0)
        \\                            (v128.const i32x4 -1 0 0 0)))))
    , "f", &.{})));
    // i8x16.relaxed_swizzle: index 2 selects a[2] = 30
    try std.testing.expectEqual(@as(i32, 30), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i8x16.extract_lane_u 0
        \\  (i8x16.relaxed_swizzle (v128.const i8x16 10 20 30 40 0 0 0 0 0 0 0 0 0 0 0 0)
        \\                         (v128.const i8x16 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))))
    , "f", &.{})));
    // i32x4.relaxed_dot_i8x16_i7x16_add_s: (2*3+4*5)+(6*7+8*9)+100 = 240
    try std.testing.expectEqual(@as(i32, 240), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i32x4.extract_lane 0
        \\  (i32x4.relaxed_dot_i8x16_i7x16_add_s
        \\    (v128.const i8x16 2 4 6 8 0 0 0 0 0 0 0 0 0 0 0 0)
        \\    (v128.const i8x16 3 5 7 9 0 0 0 0 0 0 0 0 0 0 0 0)
        \\    (v128.const i32x4 100 0 0 0)))))
    , "f", &.{})));
}

test "SIMD audit regressions (sub_sat_u / nearest / i64x2 all_true+bitmask / demote opcode / lane bounds)" {
    // sub_sat_u must saturate to 0 (was: unsigned wide underflowed → 255).
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i8x16.extract_lane_u 0
        \\  (i8x16.sub_sat_u (v128.const i8x16 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
        \\                   (v128.const i8x16 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))))
    , "f", &.{})));
    // f32x4.nearest rounds ties to even: 2.5 → 2, 3.5 → 4.
    try std.testing.expectEqual(@as(f32, 2), interp.asF32(try assembleAndRun(
        \\(module (func (export "f") (result f32) (f32x4.extract_lane 0 (f32x4.nearest (v128.const f32x4 2.5 0 0 0)))))
    , "f", &.{})));
    try std.testing.expectEqual(@as(f32, 4), interp.asF32(try assembleAndRun(
        \\(module (func (export "f") (result f32) (f32x4.extract_lane 1 (f32x4.nearest (v128.const f32x4 0 3.5 0 0)))))
    , "f", &.{})));
    // i64x2.all_true (0xc3) and i64x2.bitmask (0xc4) were missing → trapped.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i64x2.all_true (v128.const i64x2 1 2))))
    , "f", &.{})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i64x2.all_true (v128.const i64x2 1 0))))
    , "f", &.{})));
    try std.testing.expectEqual(@as(i32, 0b10), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i64x2.bitmask (v128.const i64x2 1 -1))))
    , "f", &.{})));
    // demote/promote now use the spec opcodes: run correctly AND emit 0xfd 0x5e.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(
        \\(module (func (export "f") (result i32) (i32x4.extract_lane 0
        \\  (i32x4.trunc_sat_f32x4_s (f32x4.demote_f64x2_zero (v128.const f64x2 1.5 2.5))))))
    , "f", &.{})));
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const bin = try assemble(arena.allocator(),
            \\(module (func (export "f") (result i32) (i32x4.extract_lane 0
            \\  (i32x4.trunc_sat_f32x4_s (f32x4.demote_f64x2_zero (v128.const f64x2 1.5 2.5))))))
        );
        try std.testing.expect(std.mem.indexOf(u8, bin, &[_]u8{ 0xfd, 0x5e }) != null); // demote = 0x5e (spec)
    }
    // An out-of-range lane index is rejected at DECODE (memory-safety guard): the
    // interp indexes a fixed [2]u64 by it, so lane 5 would be an OOB access.
    try std.testing.expectError(error.UnsupportedOpcode, assembleAndRun(
        \\(module (func (export "f") (result i64) (i64x2.extract_lane 5 (v128.const i64x2 1 2))))
    , "f", &.{}));
}

test "#2f: br_table with mismatched label types (unreachable code) is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Otherwise valid: the block yields f64 → drop → i32.const → the func's i32.
    // But `br_table 0 1` targets label 0 (the f64 block) and label 1 (the func,
    // result i32) — incompatible. After `unreachable` the stack is polymorphic,
    // so `popVals` can't catch it; the cross-label type check (#2f) must.
    const bin = try assemble(a,
        \\(module (func (result i32)
        \\  (block (result f64)
        \\    unreachable
        \\    (br_table 0 1 (i32.const 0)))
        \\  drop
        \\  (i32.const 5)))
    );
    var m = try Module.decode(a, bin);
    try std.testing.expectError(error.TypeMismatch, validate(a, &m));
}

test "assembles memory.size / memory.grow (WAT was missing the .mem_index arm)" {
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32) (memory.size)))
    , "f", &.{})));
    // memory.grow returns the previous size in pages (1), then memory is 3.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(
        \\(module (memory 1) (func (export "f") (result i32) (memory.grow (i32.const 2))))
    , "f", &.{})));
}

test "assembles a folded if/else" {
    const src =
        \\(module (func (export "sel") (param $c i32) (result i32)
        \\  (if (result i32) (local.get $c) (then (i32.const 111)) (else (i32.const 222)))))
    ;
    try std.testing.expectEqual(@as(i32, 111), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, 222), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(0)})));
}

test "assembles a loop with named labels (sum 1..n)" {
    const src =
        \\(module (func (export "sum") (param $n i32) (result i32) (local $acc i32)
        \\  (block $done
        \\    (loop $lp
        \\      (br_if $done (i32.eqz (local.get $n)))
        \\      (local.set $acc (i32.add (local.get $acc) (local.get $n)))
        \\      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        \\      (br $lp)))
        \\  (local.get $acc)))
    ;
    try std.testing.expectEqual(@as(i32, 15), interp.asI32(try assembleAndRun(src, "sum", &.{interp.i32Value(5)})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "sum", &.{interp.i32Value(0)})));
}

test "assembles flat block + br + end" {
    const src =
        \\(module (func (export "b") (result i32)
        \\  block (result i32)
        \\    i32.const 42
        \\    br 0
        \\  end))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "b", &.{})));
}

test "assembles memory + store/load (memarg)" {
    const src =
        \\(module (memory 1)
        \\  (func (export "rt") (param $x i32) (result i32)
        \\    (i32.store (i32.const 0) (local.get $x))
        \\    (i32.load (i32.const 0))))
    ;
    const v = try assembleAndRun(src, "rt", &.{interp.i32Value(0x12345678)});
    try std.testing.expectEqual(@as(u32, 0x12345678), @as(u32, @bitCast(interp.asI32(v))));
}

test "assembles an active data segment" {
    const src =
        \\(module (memory 1)
        \\  (data (i32.const 0) "\ef\be\ad\de")
        \\  (func (export "get") (result i32) (i32.load (i32.const 0))))
    ;
    const v = try assembleAndRun(src, "get", &.{});
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), @as(u32, @bitCast(interp.asI32(v))));
}

test "assembles a typed select" {
    const src =
        \\(module (func (export "sel") (param i32 i32 i32) (result i32)
        \\  (select (result i32) (local.get 0) (local.get 1) (local.get 2))))
    ;
    try std.testing.expectEqual(@as(i32, 10), interp.asI32(try assembleAndRun(src, "sel", &.{ interp.i32Value(10), interp.i32Value(20), interp.i32Value(1) })));
    try std.testing.expectEqual(@as(i32, 20), interp.asI32(try assembleAndRun(src, "sel", &.{ interp.i32Value(10), interp.i32Value(20), interp.i32Value(0) })));
}

test "assembles a multi-value block type" {
    // (block (param i32) (result i32) …) — a block that consumes and produces a value.
    const src =
        \\(module (func (export "mv") (param i32) (result i32)
        \\  (local.get 0)
        \\  (block (param i32) (result i32) (i32.add (i32.const 1)))))
    ;
    try std.testing.expectEqual(@as(i32, 6), interp.asI32(try assembleAndRun(src, "mv", &.{interp.i32Value(5)})));
}

test "assembles and runs call_indirect through a table" {
    const src =
        \\(module
        \\  (type $binop (func (param i32 i32) (result i32)))
        \\  (func $add (param i32 i32) (result i32) (i32.add (local.get 0) (local.get 1)))
        \\  (func $sub (param i32 i32) (result i32) (i32.sub (local.get 0) (local.get 1)))
        \\  (table funcref (elem $add $sub))
        \\  (func (export "apply") (param i32 i32 i32) (result i32)
        \\    (call_indirect (type $binop) (local.get 1) (local.get 2) (local.get 0))))
    ;
    // apply(sel, a, b): sel picks table[sel]; 0=add, 1=sub.
    try std.testing.expectEqual(@as(i32, 13), interp.asI32(try assembleAndRun(src, "apply", &.{ interp.i32Value(0), interp.i32Value(10), interp.i32Value(3) })));
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "apply", &.{ interp.i32Value(1), interp.i32Value(10), interp.i32Value(3) })));
    // Out-of-bounds table index traps.
    try std.testing.expectError(error.TableOutOfBounds, assembleAndRun(src, "apply", &.{ interp.i32Value(5), interp.i32Value(10), interp.i32Value(3) }));
}

test "assembles a mutable global (init expr + get/set)" {
    const src =
        \\(module
        \\  (global $g (mut i32) (i32.const 10))
        \\  (func (export "bump") (result i32)
        \\    (global.set $g (i32.add (global.get $g) (i32.const 5)))
        \\    (global.get $g)))
    ;
    // Init expr evaluated to 10, then +5 → 15.
    try std.testing.expectEqual(@as(i32, 15), interp.asI32(try assembleAndRun(src, "bump", &.{})));
}

test "assembles a type-reference block type" {
    const src =
        \\(module
        \\  (type $sig (func (result i32)))
        \\  (func (export "b") (result i32)
        \\    (block (type $sig) (i32.const 42))))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "b", &.{})));
}

test "exports the correct table index (not hardcoded 0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (func $a) (func $b)
        \\  (table $t0 funcref (elem $a))
        \\  (table $t1 funcref (elem $b))
        \\  (export "t1" (table $t1)))
    );
    const m = try Module.decode(a, bin);
    var found = false;
    for (m.exports) |e| {
        if (std.mem.eql(u8, e.name, "t1")) {
            try std.testing.expectEqual(@as(u32, 1), e.index); // $t1 is table index 1, not 0
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "table.size / table.grow / table.fill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (table $t 1 5 externref)
        \\  (func (export "size") (result i32) (table.size $t))
        \\  (func (export "grow") (param i32 externref) (result i32) (table.grow $t (local.get 1) (local.get 0)))
        \\  (func (export "fill") (param i32 externref i32) (table.fill $t (local.get 0) (local.get 1) (local.get 2)))
        \\  (func (export "get") (param i32) (result externref) (table.get $t (local.get 0))))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    try std.testing.expectEqual(@as(i32, 1), interp.asI32((try inst.invoke("size", &.{}))[0]));
    // grow by 2 (init 99) → returns old size 1; size now 3.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32((try inst.invoke("grow", &.{ interp.i32Value(2), interp.i64Value(99) }))[0]));
    try std.testing.expectEqual(@as(i32, 3), interp.asI32((try inst.invoke("size", &.{}))[0]));
    // grow past max (5) → -1, size unchanged.
    try std.testing.expectEqual(@as(i32, -1), interp.asI32((try inst.invoke("grow", &.{ interp.i32Value(10), interp.i64Value(0) }))[0]));
    // fill [0..2) = 77; read one back.
    _ = try inst.invoke("fill", &.{ interp.i32Value(0), interp.i64Value(77), interp.i32Value(2) });
    try std.testing.expectEqual(@as(i64, 77), interp.asI64((try inst.invoke("get", &.{interp.i32Value(1)}))[0]));
    // The grow-initialized region held 99.
    try std.testing.expectEqual(@as(i64, 99), interp.asI64((try inst.invoke("get", &.{interp.i32Value(2)}))[0]));
}

test "table.get / table.set on an externref table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (table $t 3 externref)
        \\  (func (export "set") (param i32 externref) (table.set $t (local.get 0) (local.get 1)))
        \\  (func (export "get") (param i32) (result externref) (table.get $t (local.get 0))))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    _ = try inst.invoke("set", &.{ interp.i32Value(1), interp.i64Value(42) });
    try std.testing.expectEqual(@as(i64, 42), interp.asI64((try inst.invoke("get", &.{interp.i32Value(1)}))[0]));
    // Slot 0 was never set → null reference sentinel.
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try inst.invoke("get", &.{interp.i32Value(0)}))[0]);
}

test "evaluates a compound (extended-const) global init" {
    const src =
        \\(module
        \\  (global $g i32 (i32.add (i32.mul (i32.const 20) (i32.const 2)) (i32.const 2)))
        \\  (func (export "get") (result i32) (global.get $g)))
    ;
    // 20*2 + 2 = 42.
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "get", &.{})));
}

test "reads an imported global from the host value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (global (import "env" "x") i32)
        \\  (global $y i32 (i32.add (global.get 0) (i32.const 1)))
        \\  (func (export "get-x") (result i32) (global.get 0))
        \\  (func (export "get-y") (result i32) (global.get $y)))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.initWithImports(a, &m, .{ .globals = &.{interp.i32Value(777)} });
    try std.testing.expectEqual(@as(i32, 777), interp.asI32((try inst.invoke("get-x", &.{}))[0]));
    // A defined global's init may read the imported one: 777 + 1.
    try std.testing.expectEqual(@as(i32, 778), interp.asI32((try inst.invoke("get-y", &.{}))[0]));
}

test "v128 global inits from an imported v128 global (both 64-bit halves)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (global (import "env" "v") v128)
        \\  (global $w v128 (global.get 0))
        \\  (func (export "lo") (result i32) (i32x4.extract_lane 0 (global.get $w)))
        \\  (func (export "hi") (result i32) (i32x4.extract_lane 3 (global.get $w))))
    );
    var m = try Module.decode(a, bin);
    // Imported v128 = i32x4 { 10, 20, 30, 40 }: low half is lanes 0/1, high 2/3.
    const lo: interp.Value = 10 | (@as(u64, 20) << 32);
    const hi: interp.Value = 30 | (@as(u64, 40) << 32);
    var inst = try interp.Instance.initWithImports(a, &m, .{ .globals = &.{lo}, .globals_hi = &.{hi} });
    // The defined global copied both halves — lane 0 from the low, lane 3 from the high.
    try std.testing.expectEqual(@as(i32, 10), interp.asI32((try inst.invoke("lo", &.{}))[0]));
    try std.testing.expectEqual(@as(i32, 40), interp.asI32((try inst.invoke("hi", &.{}))[0]));
}

fn hostAdd(args: []const interp.Value, results: []interp.Value) void {
    results[0] = interp.i32Value(interp.asI32(args[0]) +% interp.asI32(args[1]));
}

test "calls an imported (host) function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module
        \\  (import "env" "add" (func $add (param i32 i32) (result i32)))
        \\  (func (export "call-add") (param i32 i32) (result i32)
        \\    (call $add (local.get 0) (local.get 1))))
    );
    var m = try Module.decode(a, bin);
    const imports: interp.Instance.Imports = .{ .funcs = &.{.{ .native = hostAdd }} };
    var inst = try interp.Instance.initWithImports(a, &m, imports);
    // The imported func occupies index 0; call-add dispatches to the host adder.
    try std.testing.expectEqual(@as(i32, 7), interp.asI32((try inst.invoke("call-add", &.{ interp.i32Value(3), interp.i32Value(4) }))[0]));
}

test "inline export on a defined table (#11)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a, "(module (table (export \"t\") 2 funcref))");
    var m = try Module.decode(a, bin);
    try validate(a, &m);
    try std.testing.expectEqual(@as(usize, 1), m.exports.len);
    try std.testing.expectEqualStrings("t", m.exports[0].name);
    try std.testing.expectEqual(types.ExternKind.table, m.exports[0].type.kind());
    try std.testing.expectEqual(@as(u32, 0), m.exports[0].index);
}

test "active element-expression segment (ref.func / ref.null)" {
    const src =
        \\(module
        \\  (type $v (func (result i32)))
        \\  (func $a (result i32) (i32.const 7))
        \\  (func $b (result i32) (i32.const 9))
        \\  (table 3 funcref)
        \\  (elem (i32.const 0) funcref (ref.func $a) (ref.null func) (ref.func $b))
        \\  (func (export "call") (param i32) (result i32) (call_indirect (type $v) (local.get 0))))
    ;
    // slot 0 → $a (7), slot 2 → $b (9), slot 1 → null (traps).
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "call", &.{interp.i32Value(0)})));
    try std.testing.expectEqual(@as(i32, 9), interp.asI32(try assembleAndRun(src, "call", &.{interp.i32Value(2)})));
    try std.testing.expectError(error.UninitializedElement, assembleAndRun(src, "call", &.{interp.i32Value(1)}));
}

test "dispatches call_indirect through distinct named tables" {
    const src =
        \\(module
        \\  (type $s (func (result i32)))
        \\  (func $a (result i32) (i32.const 1))
        \\  (func $b (result i32) (i32.const 2))
        \\  (table $t0 funcref (elem $a))
        \\  (table $t1 funcref (elem $b))
        \\  (func (export "via0") (result i32) (call_indirect $t0 (type $s) (i32.const 0)))
        \\  (func (export "via1") (result i32) (call_indirect $t1 (type $s) (i32.const 0))))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "via0", &.{})));
    try std.testing.expectEqual(@as(i32, 2), interp.asI32(try assembleAndRun(src, "via1", &.{})));
}

test "atomics: load/store/rmw/cmpxchg execute correctly (values vs wasmtime)" {
    // rmw.add returns the OLD value and writes old+val.
    const add =
        \\(module (memory 1)
        \\  (func (export "f") (result i32)
        \\    (i32.atomic.store (i32.const 0) (i32.const 10))
        \\    (drop (i32.atomic.rmw.add (i32.const 0) (i32.const 5)))
        \\    (i32.atomic.load (i32.const 0))))
    ;
    try std.testing.expectEqual(@as(i32, 15), interp.asI32(try assembleAndRun(add, "f", &.{})));

    // cmpxchg replaces on a match, leaves memory on a mismatch.
    const cx =
        \\(module (memory 1)
        \\  (func (export "hit") (result i32)
        \\    (i32.atomic.store (i32.const 0) (i32.const 100))
        \\    (drop (i32.atomic.rmw.cmpxchg (i32.const 0) (i32.const 100) (i32.const 999)))
        \\    (i32.atomic.load (i32.const 0)))
        \\  (func (export "miss") (result i32)
        \\    (i32.atomic.store (i32.const 4) (i32.const 100))
        \\    (drop (i32.atomic.rmw.cmpxchg (i32.const 4) (i32.const 7) (i32.const 999)))
        \\    (i32.atomic.load (i32.const 4))))
    ;
    try std.testing.expectEqual(@as(i32, 999), interp.asI32(try assembleAndRun(cx, "hit", &.{})));
    try std.testing.expectEqual(@as(i32, 100), interp.asI32(try assembleAndRun(cx, "miss", &.{})));

    // Sub-width rmw wraps at the access width: 0x1FF as a byte is 0xFF, +1 = 0x00.
    const rmw8 =
        \\(module (memory 1)
        \\  (func (export "f") (result i32)
        \\    (i32.atomic.store (i32.const 8) (i32.const 0x1FF))
        \\    (drop (i32.atomic.rmw8.add_u (i32.const 8) (i32.const 1)))
        \\    (i32.atomic.load8_u (i32.const 8))))
    ;
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(rmw8, "f", &.{})));

    // i64.atomic.rmw.add returns the old 64-bit value.
    const i64x =
        \\(module (memory 1)
        \\  (func (export "f") (result i64)
        \\    (i64.atomic.store (i32.const 16) (i64.const 0x100000000))
        \\    (i64.atomic.rmw.add (i32.const 16) (i64.const 5))))
    ;
    try std.testing.expectEqual(@as(i64, 0x100000000), interp.asI64(try assembleAndRun(i64x, "f", &.{})));
}

test "atomics: the validator requires the natural alignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // i32.atomic.load must be align=4; align=1 is invalid (atomics are exact,
    // not "at most natural" like ordinary loads).
    const bad = try assemble(a, "(module (memory 1) (func (result i32) (i32.atomic.load align=1 (i32.const 0))))");
    var m = try Module.decode(a, bad);
    try std.testing.expectError(error.InvalidAlignment, validate(a, &m));
    // The natural alignment assembles and validates.
    const ok = try assemble(a, "(module (memory 1) (func (result i32) (i32.atomic.load align=4 (i32.const 0))))");
    var m2 = try Module.decode(a, ok);
    try validate(a, &m2);
}
test "memory64: i64 addresses, i64 size/grow, values vs wasmtime" {
    // A 64-bit memory: store/load use i64 addresses; memory.size returns i64.
    const basic =
        \\(module
        \\  (memory i64 1)
        \\  (func (export "t") (result i64)
        \\    (i64.store (i64.const 8) (i64.const 12345))
        \\    (i64.load (i64.const 8)))
        \\  (func (export "sz") (result i64) (memory.size)))
    ;
    try std.testing.expectEqual(@as(i64, 12345), interp.asI64(try assembleAndRun(basic, "t", &.{})));
    try std.testing.expectEqual(@as(i64, 1), interp.asI64(try assembleAndRun(basic, "sz", &.{})));

    // memory.grow takes and returns i64: success gives the old page count, a
    // grow past the max gives -1.
    const grow =
        \\(module
        \\  (memory i64 1 4)
        \\  (func (export "ok") (result i64) (memory.grow (i64.const 2)))
        \\  (func (export "fail") (result i64) (memory.grow (i64.const 100))))
    ;
    try std.testing.expectEqual(@as(i64, 1), interp.asI64(try assembleAndRun(grow, "ok", &.{})));
    try std.testing.expectEqual(@as(i64, -1), interp.asI64(try assembleAndRun(grow, "fail", &.{})));
}

test "memory64: assembles byte-identically to a hand-declared i64 memory; i32 form differs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The i64 index type sets flag bit 2 in the memory section, so a 64-bit and
    // 32-bit memory of the same limits assemble to DIFFERENT bytes.
    const m64 = try assemble(a, "(module (memory i64 1 2))");
    const m32 = try assemble(a, "(module (memory 1 2))");
    try std.testing.expect(!std.mem.eql(u8, m64, m32));
    // Both decode + validate.
    var d64 = try Module.decode(a, m64);
    try validate(a, &d64);
    try std.testing.expect(d64.memories[0].limits.is64);
    var d32 = try Module.decode(a, m32);
    try validate(a, &d32);
    try std.testing.expect(!d32.memories[0].limits.is64);
}

test "memory64: the validator requires an i64 address on a 64-bit memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An i32 address on a 64-bit memory is a type error.
    const bad = try assemble(a, "(module (memory i64 1) (func (result i32) (i32.load (i32.const 0))))");
    var m = try Module.decode(a, bad);
    try std.testing.expectError(error.TypeMismatch, validate(a, &m));
    // The i64 address validates.
    const ok = try assemble(a, "(module (memory i64 1) (func (result i32) (i32.load (i64.const 0))))");
    var m2 = try Module.decode(a, ok);
    try validate(a, &m2);
}

test "memory64: SIMD v128 load/store use the memory's i64 address (values vs wasmtime)" {
    // v128 memory ops were memory64-blind (i32 address hard-coded in both the
    // validator and the interpreter). On an i64 memory the address is i64.
    // Store an i64x2 and read lane 1 back — wasmtime (`-W memory64=y`) gives 6789.
    const src =
        \\(module
        \\  (memory i64 1)
        \\  (func (export "f") (result i64)
        \\    (v128.store (i64.const 16) (v128.const i64x2 12345 6789))
        \\    (i64x2.extract_lane 1 (v128.load offset=0 (i64.const 16)))))
    ;
    try std.testing.expectEqual(@as(i64, 6789), interp.asI64(try assembleAndRun(src, "f", &.{})));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The validator now demands an i64 address for a v128 load on a 64-bit memory…
    const bad = try assemble(a, "(module (memory i64 1) (func (result v128) (v128.load (i32.const 0))))");
    var mb = try Module.decode(a, bad);
    try std.testing.expectError(error.TypeMismatch, validate(a, &mb));
    // …and still an i32 address on a 32-bit memory (the v128.load on an i64 addr fails).
    const bad32 = try assemble(a, "(module (memory 1) (func (result v128) (v128.load (i64.const 0))))");
    var mb32 = try Module.decode(a, bad32);
    try std.testing.expectError(error.TypeMismatch, validate(a, &mb32));
}

test "memory64: a >2^32 static memarg offset decodes+validates on i64, rejected on i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The offset is decoded as u64; on a 64-bit memory a >=2^32 offset is legal
    // (the access itself may still trap out of bounds — that's a runtime concern).
    // Previously the decoder rejected it outright (`readVarU32` -> LebOverflow).
    const ok = try assemble(a, "(module (memory i64 1) (func (result i64) (i64.load offset=0x100000000 (i64.const 0))))");
    var m = try Module.decode(a, ok);
    try validate(a, &m);
    // On a 32-bit memory that offset must NOT be accepted — it exceeds u32.
    const bad = try assemble(a, "(module (memory 1) (func (result i64) (i64.load offset=0x100000000 (i32.const 0))))");
    var mb = try Module.decode(a, bad);
    try std.testing.expectError(error.InvalidMemArgOffset, validate(a, &mb));
}

test "multi-memory SIMD text: v128 ops take an explicit memory index (values vs wasmtime)" {
    // The SIMD load/store (+lane) text form now accepts a leading memory index,
    // emitting the bit-6 memarg form. Cross-checked vs wasmtime (-W multi-memory=y).
    const src =
        \\(module
        \\  (memory $a 1)
        \\  (memory $b 1)
        \\  (func (export "f") (result i32)
        \\    (v128.store32_lane $b 3 (i32.const 0) (v128.const i32x4 10 20 30 40))
        \\    (i32.load $b (i32.const 0)))
        \\  (func (export "g") (result i32)
        \\    (v128.store $b (i32.const 16) (v128.const i32x4 100 200 300 400))
        \\    (i32x4.extract_lane 2 (v128.load $b offset=0 (i32.const 16)))))
    ;
    try std.testing.expectEqual(@as(i32, 40), interp.asI32(try assembleAndRun(src, "f", &.{})));
    try std.testing.expectEqual(@as(i32, 300), interp.asI32(try assembleAndRun(src, "g", &.{})));
}

test "wat: a memory's index type is accepted in its canonical post-clause position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The index type canonically sits after inline (export …) — previously only the
    // right-after-the-name position assembled. Both forms must now decode to is64.
    for ([_][]const u8{
        "(module (memory (export \"m\") i64 1))", // canonical: after the export clause
        "(module (memory i64 (export \"m\") 1))", // the non-canonical form we already took
    }) |m| {
        var d = try Module.decode(a, try assemble(a, m));
        try validate(a, &d);
        try std.testing.expect(d.memories[0].limits.is64);
    }
    // A SECOND index type is rejected (a stray/typo'd token, not doubled silently).
    try std.testing.expectError(error.BadImmediate, assemble(a, "(module (memory i64 i64 1))"));
    try std.testing.expectError(error.BadImmediate, assemble(a, "(module (memory i32 i64 1))"));
}

test "wat: a flat-form SIMD memory op does not swallow the following instruction" {
    // In FLAT (stack) form the SIMD memarg parse must stop at the next mnemonic,
    // not consume it as a memidx/lane. `v128.load drop …` and `v128.load8_lane 3
    // drop …` must assemble and run (regression: the memidx atom-run was greedy).
    const load =
        \\(module (memory 1)
        \\  (func (export "f") (result i32)
        \\    i32.const 0 v128.load drop
        \\    i32.const 42))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(load, "f", &.{})));
    const lane =
        \\(module (memory 1)
        \\  (func (export "g") (result i32)
        \\    i32.const 0  v128.const i32x4 1 2 3 4  v128.load8_lane 3  drop
        \\    i32.const 7))
    ;
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(lane, "g", &.{})));
}

test "multi-memory: loads/stores/fill/copy/init/size/grow target the right memory" {
    // A self-contained two-memory module. Each op names its memory by identifier;
    // the assembler emits the bit-6 memarg form and the per-op memory indices.
    // Values cross-checked against wasmtime (`-W multi-memory=y`).

    // Distinct store/load per memory: 11 into $a, 22 into $b, summed = 33.
    const store_load =
        \\(module
        \\  (memory $a 1) (memory $b 1)
        \\  (func (export "t") (result i32)
        \\    (i32.store $a (i32.const 0) (i32.const 11))
        \\    (i32.store $b (i32.const 0) (i32.const 22))
        \\    (i32.add (i32.load $a (i32.const 0)) (i32.load $b (i32.const 0)))))
    ;
    try std.testing.expectEqual(@as(i32, 33), interp.asI32(try assembleAndRun(store_load, "t", &.{})));

    // memory.fill on $b (index 1) must not touch $a: fill two 0x02 bytes at
    // offset 1 in $b, read them back (0x0202 = 514); $a stays 0.
    const fill =
        \\(module
        \\  (memory $a 1) (memory $b 1)
        \\  (func (export "fb") (result i32)
        \\    (memory.fill $b (i32.const 1) (i32.const 0x02) (i32.const 2))
        \\    (i32.load16_u $b (i32.const 1)))
        \\  (func (export "ca") (result i32) (i32.load16_u $a (i32.const 1))))
    ;
    try std.testing.expectEqual(@as(i32, 514), interp.asI32(try assembleAndRun(fill, "fb", &.{})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(fill, "ca", &.{})));

    // memory.copy from $a to $b: write 0xAB55 into $a, copy 2 bytes $a->$b, read $b.
    const copy =
        \\(module
        \\  (memory $a 1) (memory $b 1)
        \\  (func (export "c") (result i32)
        \\    (i32.store16 $a (i32.const 4) (i32.const 0xAB55))
        \\    (memory.copy $b $a (i32.const 8) (i32.const 4) (i32.const 2))
        \\    (i32.load16_u $b (i32.const 8))))
    ;
    try std.testing.expectEqual(@as(i32, 0xAB55), interp.asI32(try assembleAndRun(copy, "c", &.{})));

    // memory.init $mem $data into $b from a passive segment; read it back.
    const init =
        \\(module
        \\  (memory $a 1) (memory $b 1)
        \\  (data $d "\09\08\07\06")
        \\  (func (export "i") (result i32)
        \\    (memory.init $b $d (i32.const 0) (i32.const 0) (i32.const 4))
        \\    (i32.load8_u $b (i32.const 2))))
    ;
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(init, "i", &.{})));

    // memory.size / memory.grow per memory: $b starts at 3 pages; grow $b by 2.
    const size =
        \\(module
        \\  (memory $a 1) (memory $b 3)
        \\  (func (export "sa") (result i32) (memory.size $a))
        \\  (func (export "grow_and_size") (result i32)
        \\    (drop (memory.grow $b (i32.const 2)))
        \\    (memory.size $b)))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(size, "sa", &.{})));
    try std.testing.expectEqual(@as(i32, 5), interp.asI32(try assembleAndRun(size, "grow_and_size", &.{})));
}

test "multi-memory: active data segments target their declared memory" {
    // Two active data segments: one into $a, one into $b at offset 0. Each
    // memory reads back only its own bytes.
    const src =
        \\(module
        \\  (memory $a 1) (memory $b 1)
        \\  (data (memory $a) (i32.const 0) "\aa")
        \\  (data (memory $b) (i32.const 0) "\bb")
        \\  (func (export "ra") (result i32) (i32.load8_u $a (i32.const 0)))
        \\  (func (export "rb") (result i32) (i32.load8_u $b (i32.const 0))))
    ;
    try std.testing.expectEqual(@as(i32, 0xaa), interp.asI32(try assembleAndRun(src, "ra", &.{})));
    try std.testing.expectEqual(@as(i32, 0xbb), interp.asI32(try assembleAndRun(src, "rb", &.{})));
}

test "multi-memory: assembles byte-identically to the single-memory form for memory 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A load naming memory 0 explicitly must emit the same bytes as the implicit
    // form — bit 6 is only set for a non-zero memory index.
    const explicit = try assemble(a, "(module (memory 1) (func (result i32) (i32.load 0 (i32.const 0))))");
    const implicit = try assemble(a, "(module (memory 1) (func (result i32) (i32.load (i32.const 0))))");
    try std.testing.expectEqualSlices(u8, implicit, explicit);
}
test "anyfunc is accepted as the pre-standard spelling of funcref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `(table N anyfunc)` (MVP-era tools still emit it) must assemble, validate,
    // and produce a byte-identical module to the `funcref` spelling.
    const with_anyfunc = try assemble(a, "(module (table 4 anyfunc) (func $f) (elem (i32.const 0) $f))");
    const with_funcref = try assemble(a, "(module (table 4 funcref) (func $f) (elem (i32.const 0) $f))");
    try std.testing.expectEqualSlices(u8, with_funcref, with_anyfunc);
    var m = try Module.decode(a, with_anyfunc);
    try validate(a, &m);
}


test "GC constant instructions in global inits (struct.new / array.new* / ref.i31)" {
    // struct.new / array.new_fixed / ref.i31 in a global init allocate at
    // instantiation, before any Instance exists. Expected values cross-checked
    // against wasmtime (the GC oracle): sv=22, av=9, iv=42.
    const src =
        \\(module
        \\  (type $s (struct (field i32) (field i32)))
        \\  (type $a (array i32))
        \\  (global $g1 (ref $s) (struct.new $s (i32.const 11) (i32.const 22)))
        \\  (global $g2 (ref $a) (array.new_fixed $a 3 (i32.const 7) (i32.const 8) (i32.const 9)))
        \\  (global $g3 (ref i31) (ref.i31 (i32.const 42)))
        \\  (func (export "sv") (result i32) (struct.get $s 1 (global.get $g1)))
        \\  (func (export "av") (result i32) (array.get $a (global.get $g2) (i32.const 2)))
        \\  (func (export "iv") (result i32) (i31.get_s (global.get $g3))))
    ;
    try std.testing.expectEqual(@as(i32, 22), interp.asI32(try assembleAndRun(src, "sv", &.{})));
    try std.testing.expectEqual(@as(i32, 9), interp.asI32(try assembleAndRun(src, "av", &.{})));
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "iv", &.{})));

    // struct.new_default (i64 field defaults to 0), array.new (init 5, size 4),
    // array.new_default (len 3) — also cross-checked against wasmtime.
    const src2 =
        \\(module
        \\  (type $s (struct (field i32) (field i64)))
        \\  (type $a (array (mut i32)))
        \\  (global $d (ref $s) (struct.new_default $s))
        \\  (global $an (ref $a) (array.new $a (i32.const 5) (i32.const 4)))
        \\  (global $ad (ref $a) (array.new_default $a (i32.const 3)))
        \\  (func (export "anv") (result i32) (array.get $a (global.get $an) (i32.const 0)))
        \\  (func (export "adlen") (result i32) (array.len (global.get $ad))))
    ;
    try std.testing.expectEqual(@as(i32, 5), interp.asI32(try assembleAndRun(src2, "anv", &.{})));
    try std.testing.expectEqual(@as(i32, 3), interp.asI32(try assembleAndRun(src2, "adlen", &.{})));
}

test "GC constant instructions: validator rejects ill-typed const-exprs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An i64 operand for an i32 struct field is a type error, not accepted.
    {
        const bin = try assemble(a,
            \\(module (type $s (struct (field i32)))
            \\  (global (ref $s) (struct.new $s (i64.const 1))))
        );
        var m = try Module.decode(a, bin);
        try std.testing.expectError(error.TypeMismatch, validate(a, &m));
    }
    // struct.new_default on a struct with a non-defaultable (non-null ref) field
    // must be rejected.
    {
        const bin = try assemble(a,
            \\(module (type $s (struct (field (ref func))))
            \\  (global (ref $s) (struct.new_default $s)))
        );
        var m = try Module.decode(a, bin);
        try std.testing.expectError(error.TypeMismatch, validate(a, &m));
    }
}
test "assembles reference types (ref.null / ref.func / ref.is_null)" {
    const src =
        \\(module
        \\  (func $f)
        \\  (func (export "isnull") (param i32) (result i32)
        \\    (if (result i32) (local.get 0)
        \\      (then (ref.is_null (ref.null func)))
        \\      (else (ref.is_null (ref.func $f))))))
    ;
    // cond=1 → ref.is_null(null) = 1; cond=0 → ref.is_null(a real funcref) = 0.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "isnull", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "isnull", &.{interp.i32Value(0)})));
}

test "assembles a funcref-typed select" {
    const src =
        \\(module
        \\  (func $f)
        \\  (func (export "sel") (param i32) (result i32)
        \\    (ref.is_null
        \\      (select (result funcref) (ref.func $f) (ref.null func) (local.get 0)))))
    ;
    // cond=1 → picks ref.func $f (non-null) → is_null = 0.
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(1)})));
    // cond=0 → picks ref.null → is_null = 1.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "sel", &.{interp.i32Value(0)})));
}

test "rejects an import after a definition (#10)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A def-before-import module would silently mis-index (imports take the low
    // indices in the binary); it must be rejected instead.
    try std.testing.expectError(error.ImportAfterDefinition, assemble(a,
        \\(module (func) (import "m" "n" (func)))
    ));
    try std.testing.expectError(error.ImportAfterDefinition, assemble(a,
        \\(module (global i32 (i32.const 0)) (import "m" "n" (global f32)))
    ));
    // Valid imports-first assembles fine.
    _ = try assemble(a,
        \\(module (import "m" "n" (func)) (func))
    );
    // Tags participate too (an imported tag takes a low tag index): a defined tag
    // before a tag import must be rejected, not silently mis-indexed — both the
    // top-level and the inline import form.
    try std.testing.expectError(error.ImportAfterDefinition, assemble(a,
        \\(module (tag $d (param i32)) (import "m" "n" (tag $i (param i32))))
    ));
    try std.testing.expectError(error.ImportAfterDefinition, assemble(a,
        \\(module (tag $d (param i32)) (tag $i (import "m" "n") (param i32)))
    ));
    // Imported tag before the defined one is fine.
    _ = try assemble(a,
        \\(module (import "m" "n" (tag $i (param i32))) (tag $d (param i32)))
    );
}

test "the import section preserves source declaration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Imports were collected into per-kind lists and emitted grouped (funcs,
    // tables, mems, globals), so a source order interleaving kinds was lost —
    // and that order is the positional linking ABI a C-ABI embedder builds its
    // extern vector against. The section must now list them as declared.
    const bin = try assemble(a,
        \\(module
        \\  (import "m" "f1"   (func $f1))
        \\  (import "m" "g1"   (global $g1 i32))
        \\  (import "m" "t1"   (table $t1 1 funcref))
        \\  (import "m" "mem1" (memory $mem1 1))
        \\  (import "m" "f2"   (func $f2)))
    );
    const m = try Module.decode(a, bin);
    const want_name = [_][]const u8{ "f1", "g1", "t1", "mem1", "f2" };
    const want_kind = [_]types.ExternKind{ .func, .global, .table, .memory, .func };
    try std.testing.expectEqual(want_name.len, m.imports.len);
    for (m.imports, want_name, want_kind) |imp, nm, k| {
        try std.testing.expectEqualStrings(nm, imp.name);
        try std.testing.expectEqual(k, imp.type.kind());
    }

    // Per-kind index spaces must still be correct despite the interleaving:
    // $f1 is func 0, $f2 is func 1. Wire both to a host adder and check the sum.
    const bin2 = try assemble(a,
        \\(module
        \\  (import "m" "f1" (func $f1 (result i32)))
        \\  (import "m" "g1" (global $g1 i32))
        \\  (import "m" "f2" (func $f2 (result i32)))
        \\  (func (export "sum") (result i32)
        \\    (i32.add (i32.add (call $f1) (call $f2)) (global.get $g1))))
    );
    var m2 = try Module.decode(a, bin2);
    try validate(a, &m2); // indices resolve under validation
}

test "assembles multi-value function results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a,
        \\(module (func (export "swap") (param i32 i32) (result i32 i32)
        \\  (local.get 1) (local.get 0)))
    );
    var m = try Module.decode(a, bin);
    var inst = try interp.Instance.init(a, &m);
    const r = try inst.invoke("swap", &.{ interp.i32Value(3), interp.i32Value(7) });
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(r[0]));
    try std.testing.expectEqual(@as(i32, 3), interp.asI32(r[1]));
}

test "GC i31: ref.i31 round-trips through i31.get_s / i31.get_u" {
    // roundtrip(x) = i31.get_s(ref.i31 x); u(x) = i31.get_u(ref.i31 x).
    const src =
        \\(module
        \\  (func (export "s") (param i32) (result i32)
        \\    (i31.get_s (ref.i31 (local.get 0))))
        \\  (func (export "u") (param i32) (result i32)
        \\    (i31.get_u (ref.i31 (local.get 0)))))
    ;
    // Small positive: identity both ways.
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "s", &.{interp.i32Value(42)})));
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "u", &.{interp.i32Value(42)})));
    // -1 wraps to the 31-bit pattern 0x7fffffff: get_s sign-extends → -1,
    // get_u zero-extends → 0x7fffffff (2147483647).
    try std.testing.expectEqual(@as(i32, -1), interp.asI32(try assembleAndRun(src, "s", &.{interp.i32Value(-1)})));
    try std.testing.expectEqual(@as(i32, 2147483647), interp.asI32(try assembleAndRun(src, "u", &.{interp.i32Value(-1)})));
    // Bit 30 set (0x40000000) is the i31 sign bit: get_s → negative.
    try std.testing.expectEqual(@as(i32, -1073741824), interp.asI32(try assembleAndRun(src, "s", &.{interp.i32Value(0x40000000)})));
    try std.testing.expectEqual(@as(i32, 0x40000000), interp.asI32(try assembleAndRun(src, "u", &.{interp.i32Value(0x40000000)})));
}

test "GC i31: i31ref is non-null; ref.null i31 reports null" {
    const src =
        \\(module
        \\  (func (export "isnull") (param i32) (result i32)
        \\    (if (result i32) (local.get 0)
        \\      (then (ref.is_null (ref.null i31)))
        \\      (else (ref.is_null (ref.i31 (i32.const 7)))))))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "isnull", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "isnull", &.{interp.i32Value(0)})));
}

test "a nullable-ref local defaults to null (not 0)" {
    // Read an unset (externref) local: it must be null, so ref.is_null → 1.
    // Before the cleanup, locals were memset to 0, which reads as a non-null ref.
    const src =
        \\(module
        \\  (func (export "unset_is_null") (result i32)
        \\    (local $r externref)
        \\    (ref.is_null (local.get $r))))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "unset_is_null", &.{})));
}

test "GC i31: i31.get_s on a null i31 ref traps" {
    const src =
        \\(module
        \\  (func (export "trap") (result i32)
        \\    (i31.get_s (ref.null i31))))
    ;
    try std.testing.expectError(error.NullReference, assembleAndRun(src, "trap", &.{}));
}

test "GC i31: (ref i31) flows into an anyref local and an eqref result (subtyping)" {
    // A non-null (ref i31) must validate against an anyref-typed local (set) and
    // an eqref function result — exercises the WasmGC subtype hierarchy
    // (i31 <: eq <: any) plus non-null <: nullable in the validator.
    const src =
        \\(module
        \\  (func (export "up") (param i32) (result eqref)
        \\    (local $a anyref)
        \\    (local.set $a (ref.i31 (local.get 0)))
        \\    (ref.i31 (local.get 0))))
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin = try assemble(a, src);
    var m = try Module.decode(a, bin);
    try validate(a, &m); // must type-check: (ref i31) <: anyref and <: eqref
}


test "struct.get/set resolve a field by NAME, not just by number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Named fields must map to the SAME indices the numeric form uses: $val is
    // field 0, $next is field 1. `mk` builds {11, 22} and returns
    // val + 100*next = 11 + 2200 = 2211 — which is wrong if the names swap or
    // both resolve to 0.
    const src =
        \\(module
        \\  (type $N (struct (field $val i32) (field $next i32)))
        \\  (func $getval (param $x (ref $N)) (result i32) (struct.get $N $val (local.get $x)))
        \\  (func $getnext (param $x (ref $N)) (result i32) (struct.get $N $next (local.get $x)))
        \\  (func (export "mk") (result i32)
        \\    (local $r (ref $N))
        \\    (local.set $r (struct.new $N (i32.const 11) (i32.const 22)))
        \\    (i32.add (call $getval (local.get $r))
        \\             (i32.mul (i32.const 100) (call $getnext (local.get $r))))))
    ;
    try std.testing.expectEqual(@as(i32, 2211), interp.asI32(try assembleAndRun(src, "mk", &.{})));

    // The named form assembles byte-identically to the numeric one.
    const named = try assemble(a,
        \\(module (type $N (struct (field $val i32) (field $next i32)))
        \\  (func (export "f") (param $x (ref $N)) (result i32) (struct.get $N $next (local.get $x))))
    );
    const numeric = try assemble(a,
        \\(module (type $N (struct (field $val i32) (field $next i32)))
        \\  (func (export "f") (param $x (ref $N)) (result i32) (struct.get $N 1 (local.get $x))))
    );
    try std.testing.expectEqualSlices(u8, numeric, named);

    // An unknown field name is rejected, not silently mapped to 0.
    try std.testing.expectError(error.UnknownIdentifier, assemble(a,
        \\(module (type $N (struct (field $val i32)))
        \\  (func (export "f") (param $x (ref $N)) (result i32) (struct.get $N $nope (local.get $x))))
    ));
}
test "GC i31: validator rejects i31.get on a non-i31 reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // i31.get_s wants (ref null i31); a funcref is a disjoint hierarchy.
    const bad = try assemble(a,
        \\(module (func $f) (elem declare func $f)
        \\  (func (export "x") (result i32) (i31.get_s (ref.func $f))))
    );
    var mbad = try Module.decode(a, bad);
    try std.testing.expectError(error.TypeMismatch, validate(a, &mbad));

    // ref.i31 wants an i32 operand, not a reference.
    const bad2 = try assemble(a,
        \\(module (func (export "y") (result i32)
        \\  (i31.get_s (ref.i31 (ref.null i31)))))
    );
    var mbad2 = try Module.decode(a, bad2);
    try std.testing.expectError(error.TypeMismatch, validate(a, &mbad2));

    // A nullable i31ref must NOT satisfy a non-null (ref i31) expectation:
    // ref.as_non_null keeps refs, but feeding a plain nullable where non-null is
    // required is caught by subtyping — checked here via anyref (super) → i31ref.
    const bad3 = try assemble(a,
        \\(module (func (export "z") (param anyref) (result i32)
        \\  (i31.get_s (local.get 0))))
    );
    var mbad3 = try Module.decode(a, bad3);
    // anyref is a *super*type of i31ref, so it must not satisfy the i31.get operand.
    try std.testing.expectError(error.TypeMismatch, validate(a, &mbad3));
}

test "saturating truncation: NaN -> 0, out-of-range clamps, no trap" {
    const src =
        \\(module
        \\  (func (export "s32") (param f64) (result i32) (i32.trunc_sat_f64_s (local.get 0)))
        \\  (func (export "u32") (param f64) (result i32) (i32.trunc_sat_f64_u (local.get 0)))
        \\  (func (export "s64") (param f32) (result i64) (i64.trunc_sat_f32_s (local.get 0))))
    ;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    // In range: plain truncation.
    try std.testing.expectEqual(@as(i32, 3), interp.asI32(try assembleAndRun(src, "s32", &.{interp.f64Value(3.7)})));
    try std.testing.expectEqual(@as(i32, -3), interp.asI32(try assembleAndRun(src, "s32", &.{interp.f64Value(-3.7)})));
    // NaN -> 0 (the trapping form would error here).
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "s32", &.{interp.f64Value(nan)})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "u32", &.{interp.f64Value(nan)})));
    // Out of range saturates to min/max.
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), interp.asI32(try assembleAndRun(src, "s32", &.{interp.f64Value(inf)})));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), interp.asI32(try assembleAndRun(src, "s32", &.{interp.f64Value(-inf)})));
    // Unsigned: negatives clamp to 0, above-range to max.
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "u32", &.{interp.f64Value(-5.0)})));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), @as(u32, @bitCast(interp.asI32(try assembleAndRun(src, "u32", &.{interp.f64Value(inf)})))));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), interp.asI64(try assembleAndRun(src, "s64", &.{interp.f32Value(std.math.inf(f32))})));
}

test "bulk memory: memory.fill / memory.copy / memory.init / data.drop" {
    const src =
        \\(module
        \\  (memory 1)
        \\  (data (i32.const 0) "abcdef")
        \\  (data "XYZ")                      ;; passive segment 1
        \\  (func (export "fill") (param i32) (result i32)
        \\    (memory.fill (i32.const 16) (local.get 0) (i32.const 4))
        \\    (i32.load8_u (i32.const 18)))
        \\  (func (export "copy") (result i32)
        \\    (memory.copy (i32.const 32) (i32.const 0) (i32.const 6))
        \\    (i32.load8_u (i32.const 34)))   ;; 'c'
        \\  (func (export "overlap") (result i32)
        \\    (memory.copy (i32.const 1) (i32.const 0) (i32.const 5))
        \\    (i32.load8_u (i32.const 5)))    ;; overlapping move: 'e'
        \\  (func (export "init") (result i32)
        \\    (memory.init 1 (i32.const 64) (i32.const 0) (i32.const 3))
        \\    (i32.load8_u (i32.const 65)))   ;; 'Y'
        \\  (func (export "init_dropped") (result i32)
        \\    (data.drop 1)
        \\    (memory.init 1 (i32.const 80) (i32.const 0) (i32.const 3))
        \\    (i32.const 0)))
    ;
    // fill: memory[16..20] = byte; read one back.
    try std.testing.expectEqual(@as(i32, 0x41), interp.asI32(try assembleAndRun(src, "fill", &.{interp.i32Value(0x41)})));
    // copy: "abcdef" -> 32; mem[34] == 'c'.
    try std.testing.expectEqual(@as(i32, 'c'), interp.asI32(try assembleAndRun(src, "copy", &.{})));
    // overlapping copy must behave like memmove: "abcdef" -> shift right by 1.
    try std.testing.expectEqual(@as(i32, 'e'), interp.asI32(try assembleAndRun(src, "overlap", &.{})));
    // init from the passive segment "XYZ": mem[65] == 'Y'.
    try std.testing.expectEqual(@as(i32, 'Y'), interp.asI32(try assembleAndRun(src, "init", &.{})));
    // A dropped segment reads as empty -> the 3-byte init is out of bounds.
    try std.testing.expectError(error.MemoryOutOfBounds, assembleAndRun(src, "init_dropped", &.{}));
}

test "bulk memory: out-of-bounds fill/copy trap" {
    const src =
        \\(module
        \\  (memory 1)
        \\  (func (export "f") (result i32)
        \\    (memory.fill (i32.const 65534) (i32.const 0) (i32.const 8))
        \\    (i32.const 0))
        \\  (func (export "c") (result i32)
        \\    (memory.copy (i32.const 65535) (i32.const 0) (i32.const 4))
        \\    (i32.const 0)))
    ;
    try std.testing.expectError(error.MemoryOutOfBounds, assembleAndRun(src, "f", &.{}));
    try std.testing.expectError(error.MemoryOutOfBounds, assembleAndRun(src, "c", &.{}));
}

test "GC struct: new + get + set with numeric fields" {
    const src =
        \\(module
        \\  (type $pt (struct (field (mut i32)) (field (mut i32))))
        \\  (func (export "sum") (param i32 i32) (result i32)
        \\    (local $p structref)
        \\    (local.set $p (struct.new $pt (local.get 0) (local.get 1)))
        \\    (i32.add (struct.get $pt 0 (local.get $p))
        \\             (struct.get $pt 1 (local.get $p))))
        \\  (func (export "setget") (param i32) (result i32)
        \\    (local $p structref)
        \\    (local.set $p (struct.new_default $pt))
        \\    (struct.set $pt 1 (local.get $p) (local.get 0))
        \\    (struct.get $pt 1 (local.get $p))))
    ;
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "sum", &.{ interp.i32Value(3), interp.i32Value(4) })));
    // new_default zeroes both fields; set field 1 = 99, read it back.
    try std.testing.expectEqual(@as(i32, 99), interp.asI32(try assembleAndRun(src, "setget", &.{interp.i32Value(99)})));
}

test "GC struct: packed i8 field sign/zero-extends on get_s/get_u" {
    const src =
        \\(module
        \\  (type $b (struct (field (mut i8))))
        \\  (func (export "s") (param i32) (result i32)
        \\    (struct.get_s $b 0 (struct.new $b (local.get 0))))
        \\  (func (export "u") (param i32) (result i32)
        \\    (struct.get_u $b 0 (struct.new $b (local.get 0)))))
    ;
    // 0xff stored in an i8 field: get_s -> -1, get_u -> 255.
    try std.testing.expectEqual(@as(i32, -1), interp.asI32(try assembleAndRun(src, "s", &.{interp.i32Value(0xff)})));
    try std.testing.expectEqual(@as(i32, 255), interp.asI32(try assembleAndRun(src, "u", &.{interp.i32Value(0xff)})));
    // 200 truncates to a byte then sign-extends: 200 = 0xc8 -> -56 signed.
    try std.testing.expectEqual(@as(i32, -56), interp.asI32(try assembleAndRun(src, "s", &.{interp.i32Value(200)})));
}

test "GC array: new + get + set + len" {
    const src =
        \\(module
        \\  (type $arr (array (mut i32)))
        \\  (func (export "t") (param i32) (result i32)
        \\    (local $a arrayref)
        \\    (local.set $a (array.new $arr (i32.const 5) (i32.const 3)))
        \\    (array.set $arr (local.get $a) (i32.const 1) (local.get 0))
        \\    (i32.add (array.get $arr (local.get $a) (i32.const 1))
        \\             (i32.mul (array.len (local.get $a)) (i32.const 10)))))
    ;
    // array [5,5,5]; set a[1]=param; result = a[1] + len*10 = param + 30.
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "t", &.{interp.i32Value(12)})));
}

test "GC array: array.new_fixed builds from operands" {
    const src =
        \\(module
        \\  (type $arr (array i32))
        \\  (func (export "third") (result i32)
        \\    (array.get $arr
        \\      (array.new_fixed $arr 3 (i32.const 10) (i32.const 20) (i32.const 30))
        \\      (i32.const 2))))
    ;
    try std.testing.expectEqual(@as(i32, 30), interp.asI32(try assembleAndRun(src, "third", &.{})));
}

test "GC ref.eq: identity of struct references" {
    const src =
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  (func (export "same") (result i32)
        \\    (local $a structref)
        \\    (local.set $a (struct.new $pt (i32.const 1)))
        \\    (ref.eq (local.get $a) (local.get $a)))
        \\  (func (export "diff") (result i32)
        \\    (ref.eq (struct.new $pt (i32.const 1)) (struct.new $pt (i32.const 1))))
        \\  (func (export "null_eq") (result i32)
        \\    (ref.eq (ref.null struct) (ref.null struct))))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "same", &.{})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "diff", &.{}))); // distinct objects
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "null_eq", &.{})));
}

test "GC struct/array traps: null access and out-of-bounds" {
    const src =
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  (type $arr (array (mut i32)))
        \\  (func (export "null_get") (result i32)
        \\    (struct.get $pt 0 (ref.null struct)))
        \\  (func (export "oob") (result i32)
        \\    (local $a arrayref)
        \\    (local.set $a (array.new_default $arr (i32.const 2)))
        \\    (array.get $arr (local.get $a) (i32.const 5))))
    ;
    try std.testing.expectError(error.NullReference, assembleAndRun(src, "null_get", &.{}));
    try std.testing.expectError(error.GcOutOfBounds, assembleAndRun(src, "oob", &.{}));
}

test "GC struct: a struct field holds a nested array (GC refs stored in fields)" {
    // A struct whose second field is an arrayref: build an array, store it, then
    // read an element and the length back *through* the struct field. The field
    // type is the abstract `arrayref`, so array.get/len apply without a cast.
    const src =
        \\(module
        \\  (type $arr (array (mut i32)))
        \\  (type $box (struct (field (mut i32)) (field (mut arrayref))))
        \\  (func (export "elem0") (param i32) (result i32)
        \\    (local $b structref)
        \\    (local.set $b (struct.new $box (i32.const 7)
        \\                    (array.new $arr (local.get 0) (i32.const 4))))
        \\    (array.get $arr (struct.get $box 1 (local.get $b)) (i32.const 0)))
        \\  (func (export "boxed_len") (result i32)
        \\    (local $b structref)
        \\    (local.set $b (struct.new $box (i32.const 7)
        \\                    (array.new_default $arr (i32.const 6))))
        \\    (array.len (struct.get $box 1 (local.get $b)))))
    ;
    // elem0: array of 4 copies of param; element 0 == param.
    try std.testing.expectEqual(@as(i32, 55), interp.asI32(try assembleAndRun(src, "elem0", &.{interp.i32Value(55)})));
    // boxed_len: the stored array has length 6.
    try std.testing.expectEqual(@as(i32, 6), interp.asI32(try assembleAndRun(src, "boxed_len", &.{})));
}

test "GC ref.test: distinguishes struct / array / i31 in an anyref slot" {
    const src =
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  (type $arr (array i32))
        \\  (func (export "is") (param i32) (result i32)
        \\    (local $a anyref)
        \\    ;; sel 0 -> a struct, 1 -> an i31, 2 -> an array
        \\    (local.set $a
        \\      (if (result anyref) (i32.eq (local.get 0) (i32.const 0))
        \\        (then (struct.new $pt (i32.const 5)))
        \\        (else (if (result anyref) (i32.eq (local.get 0) (i32.const 1))
        \\          (then (ref.i31 (i32.const 9)))
        \\          (else (array.new $arr (i32.const 0) (i32.const 2)))))))
        \\    ;; pack four ref.test results into one int: struct|array|i31|eq bits
        \\    (i32.or
        \\      (i32.or (ref.test (ref struct) (local.get $a))
        \\              (i32.mul (ref.test (ref array) (local.get $a)) (i32.const 2)))
        \\      (i32.or (i32.mul (ref.test (ref i31) (local.get $a)) (i32.const 4))
        \\              (i32.mul (ref.test (ref eq) (local.get $a)) (i32.const 8))))))
    ;
    // struct: struct(1) + eq(8) = 9
    try std.testing.expectEqual(@as(i32, 9), interp.asI32(try assembleAndRun(src, "is", &.{interp.i32Value(0)})));
    // i31: i31(4) + eq(8) = 12
    try std.testing.expectEqual(@as(i32, 12), interp.asI32(try assembleAndRun(src, "is", &.{interp.i32Value(1)})));
    // array: array(2) + eq(8) = 10
    try std.testing.expectEqual(@as(i32, 10), interp.asI32(try assembleAndRun(src, "is", &.{interp.i32Value(2)})));
}

test "GC ref.test: nullability and concrete type index" {
    const src =
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  (func (export "null_nullable") (result i32)
        \\    (ref.test (ref null struct) (ref.null struct)))
        \\  (func (export "null_nonnull") (result i32)
        \\    (ref.test (ref struct) (ref.null struct)))
        \\  (func (export "concrete") (result i32)
        \\    (local $a anyref)
        \\    (local.set $a (struct.new $pt (i32.const 1)))
        \\    (ref.test (ref $pt) (local.get $a))))
    ;
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "null_nullable", &.{}))); // null matches nullable
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "null_nonnull", &.{}))); // null fails non-null
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "concrete", &.{}))); // matches its own type
}

test "GC ref.cast: success flows the value, failure and null trap" {
    const src =
        \\(module
        \\  (type $pt (struct (field (mut i32))))
        \\  (type $arr (array i32))
        \\  (func (export "cast_get") (param i32) (result i32)
        \\    (local $a anyref)
        \\    (local.set $a (struct.new $pt (local.get 0)))
        \\    (struct.get $pt 0 (ref.cast (ref $pt) (local.get $a))))
        \\  (func (export "cast_fail") (result arrayref)
        \\    (local $a anyref)
        \\    (local.set $a (struct.new $pt (i32.const 1)))
        \\    (ref.cast (ref $arr) (local.get $a)))
        \\  (func (export "cast_null_ok") (result structref)
        \\    (ref.cast (ref null struct) (ref.null struct)))
        \\  (func (export "cast_null_trap") (result structref)
        \\    (ref.cast (ref struct) (ref.null struct))))
    ;
    // A successful downcast lets struct.get read the field.
    try std.testing.expectEqual(@as(i32, 77), interp.asI32(try assembleAndRun(src, "cast_get", &.{interp.i32Value(77)})));
    // Casting a struct to an array type traps.
    try std.testing.expectError(error.CastFailure, assembleAndRun(src, "cast_fail", &.{}));
    // A nullable cast accepts null; a non-null cast of null traps.
    _ = try assembleAndRun(src, "cast_null_ok", &.{});
    try std.testing.expectError(error.CastFailure, assembleAndRun(src, "cast_null_trap", &.{}));
}

test "GC br_on_cast / br_on_cast_fail: branch on a successful/failed downcast" {
    const src =
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  ;; sel!=0 -> an i31; sel==0 -> a struct, stored as anyref.
        \\  (func $mk (param i32) (result anyref)
        \\    (if (result anyref) (local.get 0)
        \\      (then (ref.i31 (i32.const 7)))
        \\      (else (struct.new $pt (i32.const 5)))))
        \\  ;; br_on_cast: branch (and keep the (ref i31)) when the value is an i31.
        \\  (func (export "hits") (param i32) (result i32)
        \\    (block $yes (result (ref i31))
        \\      (br_on_cast $yes anyref (ref i31) (call $mk (local.get 0)))
        \\      (return (i32.const -1)))      ;; fall-through: not an i31
        \\    (i31.get_s))                     ;; branch: extract the i31 payload
        \\  ;; br_on_cast_fail: branch (carrying anyref) when NOT an i31.
        \\  (func (export "misses") (param i32) (result i32)
        \\    (block $no (result anyref)
        \\      (br_on_cast_fail $no anyref (ref i31) (call $mk (local.get 0)))
        \\      (drop) (return (i32.const 100)))  ;; fall-through: is an i31
        \\    (drop) (i32.const 200)))            ;; branch: not an i31
    ;
    // hits: i31 -> branch -> i31.get_s = 7; struct -> fall-through -> -1.
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "hits", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, -1), interp.asI32(try assembleAndRun(src, "hits", &.{interp.i32Value(0)})));
    // misses: i31 -> fall-through -> 100; struct -> branch -> 200.
    try std.testing.expectEqual(@as(i32, 100), interp.asI32(try assembleAndRun(src, "misses", &.{interp.i32Value(1)})));
    try std.testing.expectEqual(@as(i32, 200), interp.asI32(try assembleAndRun(src, "misses", &.{interp.i32Value(0)})));
}

test "GC declared subtyping: (sub $base ...) drives ref.test / ref.cast" {
    // $sub extends $base (width subtyping — field 0 aligns). The assembler now
    // emits the sub form, so the decoder records the supertype and casts walk it.
    const src =
        \\(module
        \\  (type $base (struct (field i32)))
        \\  (type $sub (sub $base (struct (field i32) (field i32))))
        \\  (func (export "sub_is_base") (result i32)
        \\    (ref.test (ref $base) (struct.new $sub (i32.const 1) (i32.const 2))))
        \\  (func (export "base_is_not_sub") (result i32)
        \\    (ref.test (ref $sub) (struct.new $base (i32.const 1))))
        \\  (func (export "cast_up_get") (result i32)
        \\    (struct.get $base 0
        \\      (ref.cast (ref $base) (struct.new $sub (i32.const 42) (i32.const 99)))))
        \\  (func (export "cast_down_fail") (result structref)
        \\    (ref.cast (ref $sub) (struct.new $base (i32.const 1)))))
    ;
    // A $sub IS a $base (declared supertype); a $base is NOT a $sub.
    try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "sub_is_base", &.{})));
    try std.testing.expectEqual(@as(i32, 0), interp.asI32(try assembleAndRun(src, "base_is_not_sub", &.{})));
    // Upcast then read the shared field 0 through $base.
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "cast_up_get", &.{})));
    // Downcasting a plain $base to (ref $sub) traps.
    try std.testing.expectError(error.CastFailure, assembleAndRun(src, "cast_down_fail", &.{}));
}

test "GC concrete value types: (ref t) params carry the exact type" {
    // A param typed `(ref $pt)` accepts a `struct.new $pt` (same concrete type)…
    const ok =
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  (func $take (param (ref $pt)) (result i32) (struct.get $pt 0 (local.get 0)))
        \\  (func (export "run") (result i32) (call $take (struct.new $pt (i32.const 5)))))
    ;
    try std.testing.expectEqual(@as(i32, 5), interp.asI32(try assembleAndRun(ok, "run", &.{})));

    // …but validation *rejects* a `struct.new $qt` of a different concrete type
    // (previously both collapsed to `structref` and this slipped through).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try assemble(a,
        \\(module
        \\  (type $pt (struct (field i32)))
        \\  (type $qt (struct (field i32) (field i32)))
        \\  (func $take (param (ref $pt)) (result i32) (struct.get $pt 0 (local.get 0)))
        \\  (func (export "bad") (result i32)
        \\    (call $take (struct.new $qt (i32.const 5) (i32.const 6)))))
    );
    var m = try Module.decode(a, bad);
    try std.testing.expectError(error.TypeMismatch, validate(a, &m));
}

test "GC concrete value types: a self-referential linked list traverses a (ref null node) field" {
    const src =
        \\(module
        \\  (type $node (struct (field i32) (field (ref null $node))))
        \\  (func (export "sum2") (result i32)
        \\    (local $head (ref null $node))
        \\    (local.set $head
        \\      (struct.new $node (i32.const 10)
        \\        (struct.new $node (i32.const 20) (ref.null $node))))
        \\    (i32.add
        \\      (struct.get $node 0 (local.get $head))
        \\      (struct.get $node 0 (struct.get $node 1 (local.get $head))))))
    ;
    // The `next` field is the concrete `(ref null $node)`, so struct.get returns a
    // node ref you can struct.get again: 10 + 20 = 30.
    try std.testing.expectEqual(@as(i32, 30), interp.asI32(try assembleAndRun(src, "sum2", &.{})));
}

// --- Exception handling: WAT assembler round-trips (Phase 6.1) --------------
// Assemble EH text -> binary -> decode -> run, proving the assembler emits the
// tag section + throw/throw_ref/try_table/catch that the interpreter accepts.

test "EH wat: throw caught by a matching catch carries the payload" {
    const src =
        \\(module
        \\  (tag $e (param i32))
        \\  (func (export "f") (result i32)
        \\    (try_table (result i32) (catch $e 0)
        \\      i32.const 42
        \\      throw $e)))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "f", &.{})));
}

test "EH wat: an imported tag (both forms) leads the tag space and is thrown + caught" {
    // A tag import takes the low tag indices, so `$e` here is index 0. Throw/catch
    // by that identity within the module. Cross-checked against wasmtime `wast`
    // (a cross-module import of the tag, then invoke → 42).
    const top =
        \\(module
        \\  (import "env" "e" (tag $e (param i32)))
        \\  (func (export "f") (result i32)
        \\    (try_table (result i32) (catch $e 0) i32.const 42 throw $e)))
    ;
    const inline_form =
        \\(module
        \\  (tag $e (import "env" "e") (param i32))
        \\  (func (export "f") (result i32)
        \\    (try_table (result i32) (catch $e 0) i32.const 42 throw $e)))
    ;
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(top, "f", &.{})));
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(inline_form, "f", &.{})));
    // The two abbreviations denote the same module, so they assemble identically.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.eql(u8, try assemble(a, top), try assemble(a, inline_form)));
}

test "a tag typeuse with inline params that disagree with (type $t) is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `(type $t)` and inline `(param …)` on the same tag must match (§ typeuse).
    try std.testing.expectError(error.BadModuleField, assemble(a,
        \\(module (type $t (func (param i32))) (tag $e (type $t) (param i64)))
    ));
    // Agreeing params are fine, and so is `(type $t)` alone.
    _ = try assemble(a, "(module (type $t (func (param i32))) (tag $e (type $t) (param i32)))");
    _ = try assemble(a, "(module (type $t (func (param i32))) (tag $e (type $t)))");
}

test "a defined table larger than the entry budget is refused at instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `(table 0xffffffff funcref)` would eagerly allocate ~32 GiB of Value slots;
    // the per-instance entry budget refuses it cleanly instead. (Assembles and
    // decodes fine — the ceiling is an instantiation-time resource limit.)
    var m = try Module.decode(a, try assemble(a, "(module (table 0xffffffff funcref))"));
    try std.testing.expectError(error.TableLimitExceeded, interp.Instance.init(a, &m));
    // A modest table instantiates.
    var ok = try Module.decode(a, try assemble(a, "(module (table 10 funcref))"));
    var inst = try interp.Instance.init(a, &ok);
    inst.deinit();
}

test "EH wat: catch_all catches and control resumes after the try_table" {
    const src =
        \\(module
        \\  (tag $e)
        \\  (func (export "f") (result i32)
        \\    (try_table (catch_all 0)
        \\      throw $e)
        \\    i32.const 55))
    ;
    try std.testing.expectEqual(@as(i32, 55), interp.asI32(try assembleAndRun(src, "f", &.{})));
}

test "EH wat: an exception thrown in a callee is caught in the caller" {
    const src =
        \\(module
        \\  (tag $e)
        \\  (func $callee throw $e)
        \\  (func (export "f") (result i32)
        \\    (try_table (catch_all 0)
        \\      call $callee)
        \\    i32.const 7))
    ;
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "f", &.{})));
}

test "EH wat: flat try_table with catch_ref + throw_ref reaches an outer catch_all" {
    const src =
        \\(module
        \\  (tag $e)
        \\  (func (export "f") (result i32)
        \\    try_table (catch_all 0)
        \\      try_table (result exnref) (catch_ref $e 0)
        \\        throw $e
        \\      end
        \\      throw_ref
        \\    end
        \\    i32.const 5))
    ;
    try std.testing.expectEqual(@as(i32, 5), interp.asI32(try assembleAndRun(src, "f", &.{})));
}

test "EH wat: catch labels resolve by name to an enclosing block" {
    const src =
        \\(module
        \\  (tag $e (param i32))
        \\  (func (export "f") (result i32)
        \\    (block $out (result i32)
        \\      (try_table (catch $e $out)
        \\        i32.const 9
        \\        throw $e)
        \\      i32.const 0)))
    ;
    // The throw carries i32 9 to $out; the trailing i32.const 0 is skipped.
    try std.testing.expectEqual(@as(i32, 9), interp.asI32(try assembleAndRun(src, "f", &.{})));
}



test "assembler index-space gaps closed (13th pass)" {
    // Six independent gaps, grouped because they are all "an index space the
    // assembler could not name". Each made real toolchain output either fail to
    // assemble or — worse — assemble into something not matching its source.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // (1) An inline `(export …)` on a tag used to terminate the field loop, so
    // the export vanished AND the `(param …)` after it was never read, leaving an
    // empty `() -> ()` signature — silently, in a module that still validated.
    // 7 - 11 = -4 proves both params survived; the export is checked directly.
    {
        const src =
            \\(module (tag $t (export "e") (param i32 i32))
            \\  (func (export "f") (result i32)
            \\    (block $h (result i32 i32)
            \\      (try_table (result i32) (catch $t $h)
            \\        (i32.const 7) (i32.const 11) (throw $t)
            \\        (return (i32.const -1))))
            \\    (i32.sub)))
        ;
        const bin = try assemble(a, src);
        const m = try Module.decode(a, bin);
        var found = false;
        for (m.exports) |e| {
            if (std.mem.eql(u8, e.name, "e")) found = true;
        }
        try std.testing.expect(found);
        try std.testing.expectEqual(@as(i32, -4), interp.asI32(try assembleAndRun(src, "f", &.{})));
    }

    // (2) Module-level exports resolve AFTER all fields, so a forward reference
    // works. binaryen emits every export before the funcs they name, which made
    // this the largest single blocker in the real-world corpus.
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(
        "(module (export \"f\" (func $later)) (func $later (result i32) (i32.const 42)))",
        "f",
        &.{},
    )));

    // (3) `(export "memory" (memory $m))` — memories have no name table (there is
    // only ever one), so this was a hard UnknownIdentifier even though 0 is the
    // only possible answer. An UNDECLARED name must still be rejected, or the
    // "unresolved $name silently became 0" bug comes back.
    _ = try assemble(a, "(module (memory $m 1) (export \"memory\" (memory $m)))");
    try std.testing.expectError(error.UnknownIdentifier, assemble(a, "(module (memory $m 1) (export \"memory\" (memory $nope)))"));

    // (4) Flat (non-folded) `br_table`: the label scan accepted ANY atom, so it
    // swallowed the following instructions (`end`, `i32.const`, `return`) as
    // labels and then failed to resolve them. This is wasm2wat's default shape.
    // targets = [2, 0], default = 1.
    {
        const src =
            \\(module (func (export "f") (param i32) (result i32)
            \\  block block block local.get 0 br_table 2 0 1 end i32.const 10 return end
            \\  i32.const 20 return end i32.const 30))
        ;
        try std.testing.expectEqual(@as(i32, 30), interp.asI32(try assembleAndRun(src, "f", &.{0})));
        try std.testing.expectEqual(@as(i32, 10), interp.asI32(try assembleAndRun(src, "f", &.{1})));
        try std.testing.expectEqual(@as(i32, 20), interp.asI32(try assembleAndRun(src, "f", &.{2})));
    }

    // (5) Data segments had no name table, so `memory.init $d` / `data.drop $d`
    // were BadImmediate while the sibling elem forms resolved fine.
    {
        const src =
            \\(module (memory 1) (data $d "hello")
            \\  (func (export "f") (result i32)
            \\    (memory.init $d (i32.const 0) (i32.const 0) (i32.const 5))
            \\    (data.drop $d)
            \\    (i32.load8_u (i32.const 0))))
        ;
        try std.testing.expectEqual(@as(i32, 'h'), interp.asI32(try assembleAndRun(src, "f", &.{})));
    }

    // (6) The memory-index immediate was emitted as 0 WITHOUT being read, so
    // `(memory.size $nope)` assembled and ran against memory 0. It now resolves
    // via the memory name table (multi-memory), so a `$name` or real index works
    // and an unknown name is `UnknownIdentifier`.
    _ = try assemble(a, "(module (memory $m 1) (func (result i32) (memory.size $m)))");
    try std.testing.expectError(error.UnknownIdentifier, assemble(a, "(module (memory $m 1) (func (result i32) (memory.size $nope)))"));
    // `(memory.size 7)` is now a well-formed memory index (multi-memory is
    // supported), so it assembles; a module with only one memory then fails
    // VALIDATION on the out-of-range index rather than at assembly.
    {
        const bin = try assemble(a, "(module (memory $m 1) (func (result i32) (memory.size 7)))");
        var m = try Module.decode(a, bin);
        try std.testing.expectError(error.MissingMemory, validate(a, &m));
    }
}

test "legacy folded try assembles, validates, and runs (catch + catch_all + rethrow)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // catch binds the exception's payload; catch_all is the fallback. f(1) takes
    // the normal path (1); f(0) throws 99, caught by `catch $t`, + 1000 = 1099.
    // Assemble → decode → VALIDATE (not just the raw run path) → execute.
    {
        const src =
            \\(module (tag $t (param i32))
            \\  (func (export "f") (param i32) (result i32)
            \\    (try (result i32)
            \\      (do
            \\        (if (i32.eqz (local.get 0)) (then (throw $t (i32.const 99))))
            \\        (i32.const 1))
            \\      (catch $t (i32.add (i32.const 1000)))
            \\      (catch_all (i32.const -1)))))
        ;
        const bin = try assemble(a, src);
        var m = try Module.decode(a, bin);
        try validate(a, &m); // the gap: the interp ran legacy EH the validator rejected
        try std.testing.expectEqual(@as(i32, 1), interp.asI32(try assembleAndRun(src, "f", &.{1})));
        try std.testing.expectEqual(@as(i32, 1099), interp.asI32(try assembleAndRun(src, "f", &.{0})));
    }

    // rethrow 0 re-raises the exception the enclosing catch is handling, so it
    // reaches the outer try's handler (5).
    {
        const src =
            \\(module (tag $t (param i32))
            \\  (func (export "f") (result i32)
            \\    (try (result i32)
            \\      (do (try (result i32) (do (throw $t (i32.const 5))) (catch $t (drop) (rethrow 0))))
            \\      (catch $t))))
        ;
        const bin = try assemble(a, src);
        var m = try Module.decode(a, bin);
        try validate(a, &m);
        try std.testing.expectEqual(@as(i32, 5), interp.asI32(try assembleAndRun(src, "f", &.{})));
    }

    // The validator now REJECTS a legacy-EH module that is ill-typed: a `catch`
    // handler that fails to produce the try's declared result. (Before this pass
    // legacy EH was not validated at all, so such a module was accepted.)
    {
        const bin = try assemble(a,
            \\(module (tag $t)
            \\  (func (export "f") (result i32)
            \\    (try (result i32) (do (i32.const 1)) (catch $t))))
        );
        var m = try Module.decode(a, bin);
        try std.testing.expectError(error.StackUnderflow, validate(a, &m));
    }

    // `delegate` is rejected at assembly: the interpreter records its label but
    // never routes an exception through it, so emitting it would produce a module
    // that validates yet mis-runs.
    try std.testing.expectError(error.UnsupportedInstr, assemble(a,
        "(module (tag $t) (func (try (do (nop)) (delegate 0))))"));
}

test "legacy EH: a raw throw inside a catch handler propagates to the OUTER try, not a loop" {
    // The legacy re-throw idiom `catch (e) { … throw e; }`: a throw from WITHIN a
    // catch handler is outside that try's protected region, so it must reach the
    // ENCLOSING catch — not re-match the same handler (which looped forever, the
    // `15_LexicalShadowing_Stress` corpus hang). Distinct from `rethrow`, which
    // already popped the try first. Inner catch throws a fresh 7 → outer catch
    // returns it. Cross-checked against wasmtime's legacy-EH semantics (the .ts
    // source: inner catch runs once, then the re-throw is caught by the outer).
    const src =
        \\(module (tag $t (param i32))
        \\  (func (export "f") (result i32)
        \\    (try (result i32)
        \\      (do (try (result i32)
        \\            (do (throw $t (i32.const 5)))
        \\            (catch $t (drop) (throw $t (i32.const 7)))))
        \\      (catch $t))))
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try Module.decode(a, try assemble(a, src));
    try validate(a, &m);
    try std.testing.expectEqual(@as(i32, 7), interp.asI32(try assembleAndRun(src, "f", &.{})));
}

test "a (memory …) field may not carry unconsumed trailing forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `(pagesize N)` is custom-page-sizes syntax wazmrt does not implement. It
    // used to be DROPPED: `(memory 0 (pagesize 1))` assembled into an ordinary
    // 64 KiB-page memory that then disagreed with its own source — the reason
    // `custom-page-sizes.wast`'s `memory.grow` answered −1. A distinct error
    // keeps it a SKIP in the conformance runner rather than a claimed pass.
    try std.testing.expectError(error.UnsupportedProposal, assemble(a, "(module (memory 0 (pagesize 1)))"));
    try std.testing.expectError(error.UnsupportedProposal, assemble(a, "(module (memory 0 (pagesize 3)))"));
    try std.testing.expectError(error.UnsupportedProposal, assemble(a, "(module (memory (import \"m\" \"n\") 0 (pagesize 1)))"));

    // The hole was lists specifically — a trailing ATOM already failed, because
    // `parseU64` chokes on it. Anything unrecognised must now be refused.
    try std.testing.expectError(error.BadModuleField, assemble(a, "(module (memory 1 (nonsense 4)))"));

    // ...without refusing the forms that legitimately trail the limits.
    _ = try assemble(a, "(module (memory 1))");
    _ = try assemble(a, "(module (memory 1 2))");
    _ = try assemble(a, "(module (memory 1 2 shared))");
    _ = try assemble(a, "(module (memory i64 1 2))");
    _ = try assemble(a, "(module (memory $m (export \"m\") 1 2))");
    _ = try assemble(a, "(module (memory (data \"abc\")))");
}

test "the assembler emits a data-count section for any module with data segments" {
    // §5.5.16 requires it once a body uses `memory.init`/`data.drop`, and we
    // emitted it never — so every such module this assembler produced was
    // malformed. Invisible until the decoder started enforcing the rule, since
    // the two gaps agreed with each other.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\(module (memory 1) (data $d "abc")
        \\  (func (export "f")
        \\    (memory.init $d (i32.const 0) (i32.const 0) (i32.const 3))
        \\    (data.drop $d)))
    ;
    var m = try Module.decode(a, try assemble(a, src));
    try std.testing.expectEqual(@as(?u32, 1), m.data_count);
    try validate(a, &m); // would be `DataCountRequired` without the section

    // No data segments ⇒ no section, which is equally required: an empty
    // data-count section would then disagree with nothing but still be noise.
    const m2 = try Module.decode(a, try assemble(a, "(module (memory 1))"));
    try std.testing.expectEqual(@as(?u32, null), m2.data_count);
}

test "legacy rethrow re-raises from the CURRENT position, so an inner try catches it" {
    // `rethrow.wast`'s `rethrow-recatch`: the label picks WHICH exception, not
    // where propagation starts. `rethrow 2` names the outer catch but fires from
    // inside an inner try, so that inner try must catch it.
    //
    // This trapped with `UncaughtException`, because `rethrow` popped the label
    // stack down past its target first — destroying exactly the intervening try
    // that should have caught. The pop was a workaround for the target's own
    // handler re-matching, which `throwException` has handled since 2026-07-27.
    const src =
        \\(module (tag $e0)
        \\  (func (export "f") (param i32) (result i32)
        \\    (try (result i32)
        \\      (do (throw $e0))
        \\      (catch $e0
        \\        (try (result i32)
        \\          (do (if (i32.eqz (local.get 0)) (then (rethrow 2))) (i32.const 42))
        \\          (catch $e0 (i32.const 23)))))))
    ;
    // 0 -> rethrow fires, inner catch takes it; 1 -> no rethrow, falls through.
    try std.testing.expectEqual(@as(i32, 23), interp.asI32(try assembleAndRun(src, "f", &.{interp.i32Value(0)})));
    try std.testing.expectEqual(@as(i32, 42), interp.asI32(try assembleAndRun(src, "f", &.{interp.i32Value(1)})));
}

test "a rethrow label must name a catch block" {
    // `rethrow l` re-raises the exception caught AT `l`; no other label kind
    // binds one. We checked only that the label resolved, so both of these were
    // accepted and then read whatever the enclosing frame had left behind.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "(module (func (rethrow 0)))", // the function body's implicit block
        "(module (func (block (rethrow 0))))", // a plain block
        "(module (func (loop (rethrow 0))))", // sibling: a loop
        "(module (tag $e) (func (try (do (rethrow 0)) (catch $e))))", // the try's BODY, not its catch
    }) |src| {
        var m = try Module.decode(a, try assemble(a, src));
        try std.testing.expectError(error.InvalidRethrowLabel, validate(a, &m));
    }

    // ...and the valid forms must still validate: label 0 from directly inside a
    // catch, and a label reaching further out past an intervening block.
    for ([_][]const u8{
        "(module (tag $e) (func (try (do (throw $e)) (catch $e (rethrow 0)))))",
        "(module (tag $e) (func (try (do (throw $e)) (catch_all (rethrow 0)))))",
        "(module (tag $e) (func (try (do (throw $e)) (catch $e (block (rethrow 1))))))",
    }) |src| {
        var m = try Module.decode(a, try assemble(a, src));
        try validate(a, &m);
    }
}

test "rec groups survive assembly, and position within a group is part of identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The assembler used to flatten `(rec …)` into ungrouped types, which is a
    // DIFFERENT module: every member became its own singleton group, and
    // structurally identical members from different groups then canonicalised
    // together. Here `$f1` and `$f2` are both `(func)`, but sit at different
    // positions in non-isomorphic groups, so they are distinct types and the
    // global must be rejected.
    {
        const src =
            \\(module
            \\  (rec (type $f1 (func)) (type (struct)))
            \\  (rec (type (struct)) (type $f2 (func)))
            \\  (func $f (type $f2))
            \\  (global (ref $f1) (ref.func $f)))
        ;
        var m = try Module.decode(a, try assemble(a, src));
        try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, m.canon);
        try std.testing.expectError(error.TypeMismatch, validate(a, &m));
    }
    // ...but two ISOMORPHIC groups do define the same types, so the same shape
    // with the members in the same order must validate.
    {
        const src =
            \\(module
            \\  (rec (type $f1 (func)) (type (struct)))
            \\  (rec (type $f2 (func)) (type (struct)))
            \\  (func $f (type $f2))
            \\  (global (ref $f1) (ref.func $f)))
        ;
        var m = try Module.decode(a, try assemble(a, src));
        // Group 2 canonicalises onto group 1: same ids, so `$f1` == `$f2`.
        try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0, 1 }, m.canon);
        try validate(a, &m);
    }
}

test "a declared supertype must actually be one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // We recorded `supertypes[i]` and never checked it, so any type could be
    // declared the supertype of any other — and `isSubtype` then agreed, which
    // makes `ref.cast` succeed on a value that does not have the target type.
    for ([_][]const u8{
        // Final: a bare composite type is `sub final`, so it is closed.
        "(module (type $t (func)) (type $s (sub $t (func))))",
        "(module (type $t (struct)) (type $s (sub $t (struct))))",
        // Kind mismatch.
        "(module (type $f (sub (func (param i32)))) (type $s (sub $f (struct))))",
        // Array element type must match.
        "(module (type $a (sub (array i32))) (type $b (sub $a (array i64))))",
        // Mutability is invariant, and cannot be re-opened.
        "(module (type $a (sub (array (ref any)))) (type $b (sub $a (array (mut (ref any))))))",
        // Function arity/params must match.
        "(module (type $f (sub (func))) (type $g (sub $f (func (param i32)))))",
        // A struct subtype may add fields but not drop or retype them.
        "(module (type $s (sub (struct (field i32)))) (type $t (sub $s (struct (field i64)))))",
        "(module (type $s (sub (struct (field i32) (field i32)))) (type $t (sub $s (struct (field i32)))))",
    }) |src| {
        var m = try Module.decode(a, try assemble(a, src));
        try std.testing.expectError(error.InvalidSubtype, validate(a, &m));
    }

    // ...and the legitimate extensions must still validate.
    for ([_][]const u8{
        "(module (type $t (sub (func))) (type $s (sub $t (func))))",
        "(module (type $s (sub (struct (field i32)))) (type $t (sub $s (struct (field i32) (field i64)))))",
        "(module (type $a (sub (array i32))) (type $b (sub $a (array i32))))",
        "(module (type $a (sub (array (mut i32)))) (type $b (sub $a (array (mut i32)))))",
        // Explicit `final` with a supertype: extends, but is itself closed.
        "(module (type $t (sub (func))) (type $s (sub final $t (func))))",
    }) |src| {
        var m = try Module.decode(a, try assemble(a, src));
        try validate(a, &m);
    }
}
