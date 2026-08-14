;; A GC reference crossing an INSTANCE boundary. Reproducer for the defect found
;; 2026-08-14 and the regression test for its fix.
;;
;; BEFORE: a GC reference was a bare index into the READER's per-instance
;; `gc_heap`, so B read its OWN object at A's index — `ref.cast` succeeded and
;; `readA` returned 222 instead of 111. `refMatches` could not notice, because it
;; read the type index out of that same wrong entry and checked it against B's
;; own types: self-consistent, therefore blind.
;;
;; AFTER: a reference names (owner, index) — R2's rule for funcrefs, applied to
;; the `any` hierarchy.

(module $A
  (type $ta (struct (field i32)))
  (global (export "g") anyref (struct.new $ta (i32.const 111)))
)
(register "A" $A)

(module $B
  (type $tb (struct (field i32)))
  (global $fromA (import "A" "g") anyref)
  (global $mine (mut anyref) (ref.null any))
  (func (export "seed") (global.set $mine (struct.new $tb (i32.const 222))))

  ;; The ABSTRACT head travels: `struct`/`array`/`eq`/`any` are properties of the
  ;; object itself, so these are correct across instances, not merely safe.
  (func (export "isStruct") (result i32) (ref.test (ref struct) (global.get $fromA)))
  (func (export "isArray")  (result i32) (ref.test (ref array)  (global.get $fromA)))
  (func (export "isEq")     (result i32) (ref.test (ref eq)     (global.get $fromA)))
  (func (export "isNull")   (result i32) (ref.is_null (global.get $fromA)))

  ;; A CONCRETE target compares type INDICES, and an index only means something
  ;; inside the module that wrote it (R1). A foreign object is therefore refused
  ;; rather than judged against a number that means something else here.
  (func (export "concreteTest") (result i32) (ref.test (ref $tb) (global.get $fromA)))
  (func (export "concreteCast") (result i32)
    (struct.get $tb 0 (ref.cast (ref $tb) (global.get $fromA))))

  ;; …while the same operations on B's OWN object are unaffected.
  (func (export "ownTest") (result i32) (ref.test (ref $tb) (global.get $mine)))
  (func (export "ownRead") (result i32)
    (struct.get $tb 0 (ref.cast (ref $tb) (global.get $mine))))
)

(assert_return (invoke $B "seed"))

;; B holds an object at the same heap index A's object had. Before the fix this
;; is what made the substitution silent rather than a trap.
(assert_return (invoke $B "ownTest") (i32.const 1))
(assert_return (invoke $B "ownRead") (i32.const 222))

;; A's object is seen as a struct, not as B's object.
(assert_return (invoke $B "isNull")   (i32.const 0))
(assert_return (invoke $B "isStruct") (i32.const 1))
(assert_return (invoke $B "isArray")  (i32.const 0))
(assert_return (invoke $B "isEq")     (i32.const 1))

;; ⚠️ DELIBERATE FALSE NEGATIVE, matching R2's `definedFuncType` precedent for
;; funcrefs. The spec answer is 1 / 111 — `$ta` and `$tb` are structurally
;; identical, so the cast should succeed. Deciding that needs `typematch`, which
;; needs an allocator `refMatches` does not have on the cast hot path. A false
;; negative, loudly, instead of a wrong cast quietly. See `known-issues.md`.
(assert_return (invoke $B "concreteTest") (i32.const 0))
(assert_trap (invoke $B "concreteCast") "cast failure")
