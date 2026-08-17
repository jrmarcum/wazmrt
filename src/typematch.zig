//! Cross-module type identity and extern matching (§3.3.10 type equivalence,
//! §4.5.3 import matching).
//!
//! **The problem.** A concrete reference `(ref $t)` is stored as a `ValType`
//! carrying a MODULE-LOCAL type index. Inside one module that index is an
//! identity — `Module.canonOf` maps isomorphic rec groups onto a shared id, so
//! `Module.valTypeEq` settles equality with an integer compare. Across two
//! modules the same index number means two unrelated types, so the integer
//! compare is not merely unhelpful, it is ACTIVELY WRONG IN BOTH DIRECTIONS:
//!
//!   - it **rejects valid links** — two modules that each declare the same type
//!     hold it at different indices, so a legitimate import fails to match;
//!   - it **accepts invalid ones** — `(ref $A)` at index 0 in one module and an
//!     unrelated `(ref $B)` at index 0 in another compare EQUAL, and the importer
//!     then receives values of a type it never agreed to. That is type confusion
//!     across a module boundary, reached by ordinary linking, and it is the reason
//!     this file exists rather than a widened integer.
//!
//! **The approach.** Types are compared STRUCTURALLY, walking both modules' type
//! sections in step, under *iso*-recursive rules (§3.3.10): the unit of identity
//! is the whole rec group, and two types are the same only if they sit at the same
//! position in equivalent groups. Equi-recursive comparison — unfold both to
//! infinite trees and compare those — is the tempting simplification and is too
//! permissive: it would equate a self-referential group of one with a mutually
//! referential group of two, which the spec keeps distinct.
//!
//! **Termination.** Within a group, references BACK INTO the group are compared
//! by position and never recursed on; only references leaving the group recurse,
//! and those point strictly backwards (`Module.checkTypeRefScope` enforces it at
//! decode). So the recursion is well-founded on group start index. The in-progress
//! set is a belt-and-braces cycle guard, not the mechanism — see `Ctx.eqGroup`.

const std = @import("std");
const types = @import("types.zig");
const Module = @import("Module.zig");

const V = types.ValType;

/// Spelled out rather than inferred: the comparison functions below are MUTUALLY
/// recursive (`typeEq` → `eqGroup` → `eqMember` → `eqRef` → `typeEq`), which an
/// inferred error set cannot resolve. Allocation — growing the memo — is the only
/// way any of them fails.
pub const Error = std.mem.Allocator.Error;

/// A pair of rec groups being compared: each is a module plus the group's start
/// index.
///
/// ⚠️ **The module pointers are load-bearing, not decoration.** Keying on the two
/// start indices alone made the memo say "group 0 vs group 0" — a statement about
/// no particular modules — so one link's answer was served to an unrelated later
/// link, and 32 import assertions flipped to whatever the first pair had decided.
/// A cache key must name everything the answer depends on.
const Pair = struct { ma: *const Module, a: u32, mb: *const Module, b: u32 };

/// Matching state: the memo table that keeps comparison polynomial rather than
/// exponential, plus the allocator backing it.
///
/// Scoped to ONE link (`init` at the top of import resolution, `deinit` at the
/// end), which is where the sharing pays — a module's imports typically name a
/// handful of the provider's groups over and over. Living no longer than the link
/// also means every module a key names is provably still alive.
pub const Ctx = struct {
    a: std.mem.Allocator,
    /// Decided group-pair results, keyed by the two groups' start indices.
    memo: std.AutoHashMapUnmanaged(Pair, bool) = .empty,
    /// Group pairs currently being compared further up the stack.
    in_progress: std.AutoHashMapUnmanaged(Pair, void) = .empty,

    pub fn init(a: std.mem.Allocator) Ctx {
        return .{ .a = a };
    }

    pub fn deinit(self: *Ctx) void {
        self.memo.deinit(self.a);
        self.in_progress.deinit(self.a);
    }

    /// Are `ma`'s type index `ia` and `mb`'s type index `ib` the SAME type?
    ///
    /// Same position in equivalent rec groups. Comparing positions before groups
    /// is what makes this iso-recursive: `(rec $x)` and `(rec $y $z)` can never
    /// match however their bodies unfold.
    pub fn typeEq(self: *Ctx, ma: *const Module, ia: u32, mb: *const Module, ib: u32) Error!bool {
        const ga = ma.recGroup(ia);
        const gb = mb.recGroup(ib);
        if (ga.len != gb.len) return false;
        if (ia - ga.start != ib - gb.start) return false;
        return self.eqGroup(ma, ga.start, ga.len, mb, gb.start);
    }

    /// Are the two rec groups equivalent, member for member?
    fn eqGroup(self: *Ctx, ma: *const Module, sa: u32, len: u32, mb: *const Module, sb: u32) Error!bool {
        const key: Pair = .{ .ma = ma, .a = sa, .mb = mb, .b = sb };
        if (self.memo.get(key)) |decided| return decided;
        // A pair still on the stack can only be reached again through a reference
        // that leaves its group and comes back — impossible once type references
        // are scoped, so this arm is unreachable for any module that decoded.
        // It stays because the alternative to a wrong answer here is a hang: a
        // hand-built binary that slipped a cycle past decode must terminate, and
        // "assume equal" is the standard coinductive reading of an open goal.
        if (self.in_progress.contains(key)) return true;
        try self.in_progress.put(self.a, key, {});
        defer _ = self.in_progress.remove(key);

        var ok = true;
        var k: u32 = 0;
        while (k < len) : (k += 1) {
            if (!try self.eqMember(ma, sa, len, sa + k, mb, sb, sb + k)) {
                ok = false;
                break;
            }
        }
        try self.memo.put(self.a, key, ok);
        return ok;
    }

    /// One member of each group: finality, declared supertype, composite body.
    ///
    /// Finality is part of the type, not a note about it — `(sub (func))` and
    /// `(sub final (func))` describe the same signature and are different types,
    /// because only one of them may be extended.
    fn eqMember(self: *Ctx, ma: *const Module, sa: u32, len: u32, ta: u32, mb: *const Module, sb: u32, tb: u32) Error!bool {
        if (ma.isFinal(ta) != mb.isFinal(tb)) return false;

        const supa: ?u32 = if (ta < ma.supertypes.len) ma.supertypes[ta] else null;
        const supb: ?u32 = if (tb < mb.supertypes.len) mb.supertypes[tb] else null;
        if ((supa == null) != (supb == null)) return false;
        if (supa) |x| if (!try self.eqRef(ma, sa, len, x, mb, sb, supb.?)) return false;

        // custom-descriptors links, compared exactly like the supertype above:
        // a type that carries a description and one that does not are different
        // types, so an import whose declared type omits the clause must not
        // match an export that has it — the cross-module face of the same rule
        // `interp.groupKey` enforces inside a store.
        const desc_a = [_]?u32{ ma.descriptorOf(ta), ma.describesOf(ta) };
        const desc_b = [_]?u32{ mb.descriptorOf(tb), mb.describesOf(tb) };
        for (desc_a, desc_b) |x, y| {
            if ((x == null) != (y == null)) return false;
            if (x) |xi| if (!try self.eqRef(ma, sa, len, xi, mb, sb, y.?)) return false;
        }

        if (ta >= ma.comp_types.len or tb >= mb.comp_types.len) return false;
        return self.eqComp(ma, sa, len, ma.comp_types[ta], mb, sb, mb.comp_types[tb]);
    }

    /// Compare two type REFERENCES appearing at the same spot in the two groups.
    ///
    /// A reference into its own group is compared by POSITION — this is the step
    /// that makes two isomorphic recursive groups equal without unfolding them,
    /// and the step that stops the recursion. A reference out of the group is a
    /// reference to an already-defined type, so it recurses.
    fn eqRef(self: *Ctx, ma: *const Module, sa: u32, len: u32, ra: u32, mb: *const Module, sb: u32, rb: u32) Error!bool {
        const in_a = ra >= sa and ra < sa + len;
        const in_b = rb >= sb and rb < sb + len;
        if (in_a != in_b) return false;
        if (in_a) return ra - sa == rb - sb;
        return self.typeEq(ma, ra, mb, rb);
    }

    fn eqComp(self: *Ctx, ma: *const Module, sa: u32, len: u32, ca: Module.CompType, mb: *const Module, sb: u32, cb: Module.CompType) Error!bool {
        return switch (ca) {
            .func => |fa| switch (cb) {
                .func => |fb| try self.eqValTypes(ma, sa, len, fa.params, mb, sb, fb.params) and
                    try self.eqValTypes(ma, sa, len, fa.results, mb, sb, fb.results),
                else => false,
            },
            .@"struct" => |fa| switch (cb) {
                .@"struct" => |fb| blk: {
                    if (fa.len != fb.len) break :blk false;
                    for (fa, fb) |x, y| if (!try self.eqField(ma, sa, len, x, mb, sb, y)) break :blk false;
                    break :blk true;
                },
                else => false,
            },
            .array => |fa| switch (cb) {
                .array => |fb| self.eqField(ma, sa, len, fa, mb, sb, fb),
                else => false,
            },
        };
    }

    fn eqField(self: *Ctx, ma: *const Module, sa: u32, len: u32, fa: Module.FieldType, mb: *const Module, sb: u32, fb: Module.FieldType) Error!bool {
        if (fa.mutable != fb.mutable) return false;
        if (std.meta.activeTag(fa.storage) != std.meta.activeTag(fb.storage)) return false;
        return switch (fa.storage) {
            .val => |v| self.eqValType(ma, sa, len, v, mb, sb, fb.storage.val),
            .i8, .i16 => true, // the tag comparison above already settled these
        };
    }

    fn eqValTypes(self: *Ctx, ma: *const Module, sa: u32, len: u32, xs: []const V, mb: *const Module, sb: u32, ys: []const V) Error!bool {
        if (xs.len != ys.len) return false;
        for (xs, ys) |x, y| if (!try self.eqValType(ma, sa, len, x, mb, sb, y)) return false;
        return true;
    }

    fn eqValType(self: *Ctx, ma: *const Module, sa: u32, len: u32, x: V, mb: *const Module, sb: u32, y: V) Error!bool {
        if (!x.isConcrete() or !y.isConcrete()) return x == y;
        if (x.flagBits() != y.flagBits()) return false;
        return self.eqRef(ma, sa, len, x.concreteIndex(), mb, sb, y.concreteIndex());
    }

    // --- Subtyping -----------------------------------------------------------

    /// Is `ma`'s type index `ia` a subtype of `mb`'s type index `ib`?
    ///
    /// Walks the DECLARED supertype chain on the sub side — WebAssembly subtyping
    /// is nominal-by-declaration, not structural, so a type that merely looks like
    /// a supertype is not one.
    pub fn typeSub(self: *Ctx, ma: *const Module, ia: u32, mb: *const Module, ib: u32) Error!bool {
        var cur: ?u32 = ia;
        // The chain is strictly decreasing by construction (`decodeSubType`
        // rejects a supertype that does not precede its type), so this ends.
        while (cur) |c| {
            if (try self.typeEq(ma, c, mb, ib)) return true;
            cur = if (c < ma.supertypes.len) ma.supertypes[c] else null;
        }
        return false;
    }

    /// Is value type `x` (in `ma`) a subtype of `y` (in `mb`)? The abstract
    /// hierarchy is module-independent, so only the concrete cases cross over.
    pub fn valTypeSub(self: *Ctx, ma: *const Module, x: V, mb: *const Module, y: V) Error!bool {
        if (!x.isRef() or !y.isRef()) return x == y;
        if (y.isNonNullRef() and !x.isNonNullRef()) return false;
        if (x.isConcrete() and y.isConcrete()) {
            if (x.refHeap() != y.refHeap()) return false;
            return self.typeSub(ma, x.concreteIndex(), mb, y.concreteIndex());
        }
        // A concrete sub satisfies an abstract sup through its family head; an
        // abstract sub satisfies a concrete sup only as the bottom type `none`.
        if (x.isConcrete()) return x.refHeap().sub(y.refHeap());
        if (y.isConcrete()) return x.refHeap() == .none;
        return x.refHeap().sub(y.refHeap());
    }

    // --- §4.5.3 extern matching ---------------------------------------------

    /// Does the function at type index `pi` in `pm` (the PROVIDER's export)
    /// satisfy an import declared at type index `ri` in `rm`?
    ///
    /// Function types are related by subtyping, not equality (§4.5.3): a provider
    /// whose type is a declared subtype of the required one is a valid link.
    pub fn funcImportOk(self: *Ctx, pm: *const Module, pi: u32, rm: *const Module, ri: u32) Error!bool {
        return self.typeSub(pm, pi, rm, ri);
    }

    /// Global matching: an immutable global is covariant in its content type, a
    /// mutable one is INVARIANT — it is written through the import as well as
    /// read, so widening in either direction is unsound.
    pub fn globalImportOk(self: *Ctx, pm: *const Module, p: Module.GlobalType, rm: *const Module, r: Module.GlobalType) Error!bool {
        if (p.mutable != r.mutable) return false;
        if (r.mutable) {
            return try self.valTypeSub(pm, p.content, rm, r.content) and
                try self.valTypeSub(rm, r.content, pm, p.content);
        }
        return self.valTypeSub(pm, p.content, rm, r.content);
    }

    /// Table element matching. A table is read AND written through its type, so
    /// the element type is invariant — mutual subtyping, i.e. equivalence.
    pub fn tableElemOk(self: *Ctx, pm: *const Module, p: V, rm: *const Module, r: V) Error!bool {
        return try self.valTypeSub(pm, p, rm, r) and try self.valTypeSub(rm, r, pm, p);
    }

    /// Tag matching (EH proposal). A tag's type is its identity — an exception
    /// thrown by the provider must be caught with exactly the payload the importer
    /// declared, so this is equivalence, not subtyping.
    pub fn tagImportOk(self: *Ctx, pm: *const Module, pi: u32, rm: *const Module, ri: u32) Error!bool {
        return self.typeEq(pm, pi, rm, ri);
    }
};

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

/// Assemble `src` (WAT text) and decode it, so the tests below describe types the
/// way the spec does rather than as hand-built bytes.
fn buildModule(a: std.mem.Allocator, src: []const u8) !Module {
    const wat = @import("wat.zig");
    // The assembler allocates the parsed s-expressions and its own scratch from
    // the same allocator and hands back a slice into that; an arena is the only
    // sound way to reclaim it. `Module.decode` copies out everything it keeps.
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return Module.decode(a, try wat.assemble(scratch.allocator(), src));
}

test "isomorphic rec groups in different modules are the same type" {
    const a = testing.allocator;
    // Same group, but preceded by a filler type in `mb` so the indices differ —
    // the whole point is that the index must not decide the answer.
    var ma = try buildModule(a, "(module (rec (type $t (func (param i32 (ref $t))))))");
    defer ma.deinit();
    var mb = try buildModule(a,
        \\(module
        \\  (type $pad (func (result f64)))
        \\  (rec (type $t (func (param i32 (ref $t)))))
        \\)
    );
    defer mb.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    try testing.expect(try ctx.typeEq(&ma, 0, &mb, 1));
    // ...and the filler is NOT that type, though `ma`'s index 0 equals its index.
    try testing.expect(!try ctx.typeEq(&ma, 0, &mb, 0));
}

test "same index in two modules is not the same type" {
    const a = testing.allocator;
    var ma = try buildModule(a, "(module (type $t (func (param i32))))");
    defer ma.deinit();
    var mb = try buildModule(a, "(module (type $t (func (param f32))))");
    defer mb.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    // The regression this file exists for: both are type index 0, and comparing
    // the `ValType` bit patterns of a `(ref 0)` would call them equal.
    try testing.expect(!try ctx.typeEq(&ma, 0, &mb, 0));
}

test "rec group SHAPE distinguishes types that unfold alike" {
    const a = testing.allocator;
    // Iso-recursive, not equi-recursive: both unfold to the same infinite tree,
    // but one group has one member and the other has two.
    var ma = try buildModule(a, "(module (rec (type $t (func (param (ref $t))))))");
    defer ma.deinit();
    var mb = try buildModule(a,
        \\(module (rec
        \\  (type $u (func (param (ref $v))))
        \\  (type $v (func (param (ref $u))))
        \\))
    );
    defer mb.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    try testing.expect(!try ctx.typeEq(&ma, 0, &mb, 0));
}

test "finality is part of the type" {
    const a = testing.allocator;
    var ma = try buildModule(a, "(module (type $t (sub (func))))");
    defer ma.deinit();
    var mb = try buildModule(a, "(module (type $t (sub final (func))))");
    defer mb.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    try testing.expect(!try ctx.typeEq(&ma, 0, &mb, 0));
}

test "cross-module subtyping follows the declared chain" {
    const a = testing.allocator;
    var ma = try buildModule(a,
        \\(module
        \\  (type $base (sub (func)))
        \\  (type $derived (sub $base (func)))
        \\)
    );
    defer ma.deinit();
    var mb = try buildModule(a, "(module (type $base (sub (func))))");
    defer mb.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    try testing.expect(try ctx.typeSub(&ma, 1, &mb, 0)); // derived <: base
    try testing.expect(!try ctx.typeSub(&mb, 0, &ma, 1)); // base is not <: derived
}

test "mutable global content is invariant across modules" {
    const a = testing.allocator;
    var ma = try buildModule(a,
        \\(module
        \\  (type $base (sub (func)))
        \\  (type $derived (sub $base (func)))
        \\)
    );
    defer ma.deinit();
    var mb = try buildModule(a, "(module (type $base (sub (func))))");
    defer mb.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    const provided: V = .concreteRef(true, .func, 1); // (ref null $derived) in ma
    const required: V = .concreteRef(true, .func, 0); // (ref null $base) in mb

    try testing.expect(try ctx.globalImportOk(
        &ma,
        .{ .content = provided, .mutable = false },
        &mb,
        .{ .content = required, .mutable = false },
    ));
    try testing.expect(!try ctx.globalImportOk(
        &ma,
        .{ .content = provided, .mutable = true },
        &mb,
        .{ .content = required, .mutable = true },
    ));
}

test "D2: a descriptor link is part of the type ACROSS modules" {
    const a = testing.allocator;
    // 🔒 The cross-module face of the `groupKey` trap. This is the comparison an IMPORT goes
    // through, so answering "same type" here lets a module import a described `(ref $t)` and be
    // linked against an export that carries no description at all — the value arrives promising a
    // descriptor it does not have, and D3's `ref.get_desc` would read a field nothing ever wrote.
    var described = try buildModule(a, "(module (rec (type $a (descriptor $b) (struct)) (type $b (describes $a) (struct))))");
    defer described.deinit();
    var plain = try buildModule(a, "(module (rec (type $a (struct)) (type $b (struct))))");
    defer plain.deinit();
    // Same shape, same links, different module — this pair MUST still match, or the check above
    // would be passing because descriptors simply never compare equal.
    var described2 = try buildModule(a, "(module (rec (type $x (descriptor $y) (struct)) (type $y (describes $x) (struct))))");
    defer described2.deinit();

    var ctx: Ctx = .init(a);
    defer ctx.deinit();
    try testing.expect(!try ctx.typeEq(&described, 0, &plain, 0));
    try testing.expect(!try ctx.typeEq(&described, 1, &plain, 1));
    try testing.expect(try ctx.typeEq(&described, 0, &described2, 0));
    try testing.expect(try ctx.typeEq(&described, 1, &described2, 1));
    // Nor does the structural walk quietly make one a SUBTYPE of the other.
    try testing.expect(!try ctx.typeSub(&described, 0, &plain, 0));
    try testing.expect(!try ctx.typeSub(&plain, 0, &described, 0));
}
