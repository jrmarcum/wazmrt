/*
 * wazmrt.h — the public C ABI for the wazmrt WebAssembly runtime.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 * Copyright (c) 2026 Jon Marcum
 *
 * A small, wasmtime-SHAPED engine surface under our own `wazmrt_*` names. It is NOT the
 * standard wasm-c-api and NOT wasmtime's exact symbols.
 *
 * WHY NOT wasm-c-api. wazmrt shipped that surface first — 319 declared functions, 176
 * exports — and it was the wrong ABI for the consumers it was chosen to serve: the
 * `universalWasmLoader-*` projects bind to wasmtime's `wasmtime_*` store/context/linker
 * model, and wasm-c-api's host callback receives NO handle to the caller's memory, which is
 * what essentially every real host import needs. It also concentrated risk: every C-ABI
 * audit finding this project has ever had (#20, #21, #22 — 180 undefined symbols, a double
 * free, a use-after-free, an uninitialised refcount, two more from a lifecycle fuzz) lived
 * in that one file, because a refcounted object model hands raw ownership across C.
 * This header keeps the standard's good idea — a stable, documented engine ABI — and drops
 * the object model in favour of value handles (below).
 *
 * SCOPE. This is the ENGINE surface. Callers that speak the Component Model do the Canonical
 * ABI marshalling themselves, on top of these primitives. That marshalling is the embedder's
 * job, not the runtime's, which is why nothing here mentions WIT or components.
 *
 * The engine EXECUTES more than this API exposes. A guest may use WasmGC, threads/atomics,
 * memory64 or exception handling internally and run correctly; the host surface simply does
 * not hand those types across the boundary. SIMD `v128` IS carried — see "Values".
 *
 * ---------------------------------------------------------------------------------------
 * Handles and ownership
 * ---------------------------------------------------------------------------------------
 * Two kinds, and the distinction is the whole ownership story:
 *
 *   1. OPAQUE POINTERS (`wazmrt_engine_t *`, `wazmrt_module_t *`, …) — you own these, and
 *      each has exactly one `_delete`. Deleting twice, or using one after deleting it, is
 *      undefined behaviour, as it would be for any C API.
 *
 *   2. VALUE HANDLES (`wazmrt_instance_t`, `wazmrt_func_t`, `wazmrt_memory_t`,
 *      `wazmrt_global_t`) — small copyable structs naming something a store owns. You do
 *      NOT free them and there is no `_delete`. Copy them freely.
 *
 *      Value handles are CHECKED, not trusted. Each carries the identity of the store it
 *      came from, so a handle used with the wrong store, or one left over from a deleted
 *      store, is rejected — you get `false` or an error, never another store's resource.
 *      That is the property a refcount model exists to provide, obtained instead by
 *      construction: there is no count to get wrong and no ownership to transfer.
 *
 * THREADING — CONCURRENCY COMES FROM MULTIPLE ENGINES.
 *
 * An engine, its stores, and everything reachable from them are single-threaded. Do not touch
 * one engine from two threads, even under an external lock. This is not a temporary limitation:
 * the engine carries a single-threaded I/O implementation on purpose, because a thread pool
 * would cost binary size in a runtime whose whole pitch is footprint.
 *
 * ⚠️ If your host uses async/await, goroutines, tasks or threads, give **each concurrent context
 * its own `wazmrt_engine_t`**. Engines are cheap and fully independent — nothing is shared
 * between them — so N engines is the supported way to run N things at once. Sharing one engine
 * across an async runtime's worker threads is undefined behaviour, and it is the mistake this
 * paragraph exists to prevent.
 *
 * ---------------------------------------------------------------------------------------
 * Error convention
 * ---------------------------------------------------------------------------------------
 *   - Functions returning `wazmrt_error_t *` return NULL on SUCCESS. A non-NULL result is
 *     an error you own and must `wazmrt_error_delete`.
 *   - A guest TRAP is not an error: it is reported through a `wazmrt_trap_t **` out-param,
 *     set only when the call actually trapped. A call can therefore return NULL (no
 *     host-side error) and still have trapped — always check both.
 *   - Functions returning `bool` return false for "not found" / "out of range", with no
 *     allocation.
 *
 * ---------------------------------------------------------------------------------------
 * Deliberate omissions (each is ADDITIVE later — adding a symbol breaks no existing caller)
 * ---------------------------------------------------------------------------------------
 *   - TABLES. No `wazmrt_table_t`. No surveyed consumer uses table access from the host, and
 *     an unused symbol is pure size in a project where `ReleaseSmall` is a stated goal. The
 *     engine still implements tables fully; only the host view is absent.
 *   - MULTI-VALUE RETURNS and imported memories/tables at the host boundary, for the same
 *     reason.
 *   If you need one, say so — it is an addition, not a redesign, and `WAZMRT_ABI_VERSION`
 *   would not have to move.
 */
#ifndef WAZMRT_H
#define WAZMRT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Version / ABI handshake ---------------------------------------------------------
 * Check `wazmrt_abi_version()` against WAZMRT_ABI_VERSION at load time when binding
 * dynamically; a mismatch means the header and the library disagree about this file.
 *
 * VERSION 2 IS A CLEAN BREAK. Version 1 was the wasm-c-api surface (`wasm_*` symbols from a
 * vendored `wasm.h`). Nothing from it survives — the symbols are gone, not deprecated — so a
 * v1 consumer fails to LINK rather than mislinking. The bump exists so a consumer that binds
 * dynamically and only checks the number still finds out.
 */
#define WAZMRT_ABI_VERSION 2u

uint32_t    wazmrt_abi_version(void);     /* bumped on any breaking change to this header */
const char *wazmrt_version_string(void);  /* e.g. "0.1.0"; static storage, do not free     */

/* ---- Opaque handles (owned; each has exactly one _delete) ---------------------------- */
typedef struct wazmrt_engine      wazmrt_engine_t;
typedef struct wazmrt_config      wazmrt_config_t;
typedef struct wazmrt_store       wazmrt_store_t;
typedef struct wazmrt_module      wazmrt_module_t;
typedef struct wazmrt_linker      wazmrt_linker_t;
typedef struct wazmrt_functype    wazmrt_functype_t;
typedef struct wazmrt_trap        wazmrt_trap_t;   /* a guest trap                            */
typedef struct wazmrt_error       wazmrt_error_t;  /* a host-side error (compile/link/misuse) */
typedef struct wazmrt_caller      wazmrt_caller_t; /* VALID ONLY during a host callback       */
typedef struct wazmrt_wasi_config wazmrt_wasi_config_t;

/* ---- Value handles (not owned; no _delete; checked on use) ---------------------------- */
typedef struct { uint64_t id; } wazmrt_instance_t;
typedef struct { uint64_t id; } wazmrt_func_t;
typedef struct { uint64_t id; } wazmrt_memory_t;
typedef struct { uint64_t id; } wazmrt_global_t;

/* Does this handle still name something in `store`? False for a handle from another store,
 * from a deleted store, or never initialized. */
bool wazmrt_instance_is_valid(const wazmrt_store_t *, wazmrt_instance_t);
bool wazmrt_func_is_valid(const wazmrt_store_t *, wazmrt_func_t);
bool wazmrt_memory_is_valid(const wazmrt_store_t *, wazmrt_memory_t);
bool wazmrt_global_is_valid(const wazmrt_store_t *, wazmrt_global_t);

/* ---- Values ---------------------------------------------------------------------------
 * The types that cross the host boundary. A guest may use the GC reference types internally;
 * they cannot be passed to or from a host call, and calling an export whose signature
 * contains one returns an error rather than marshalling something wrong.
 *
 * `v128` IS carried, deliberately. The previous ABI could not: the vendored `wasm.h` had no
 * v128 valkind, so vectors were smuggled as two 64-bit slots — and that workaround produced
 * real bugs (a call returning 3 instead of 22; half a vector punned as a pointer). Our own
 * header has no such constraint, so a vector is simply 16 bytes.
 */
typedef enum {
    WAZMRT_I32       = 0,
    WAZMRT_I64       = 1,
    WAZMRT_F32       = 2,
    WAZMRT_F64       = 3,
    WAZMRT_FUNCREF   = 4,  /* opaque to the host: pass it back unchanged */
    WAZMRT_EXTERNREF = 5,  /* likewise                                   */
    WAZMRT_V128      = 6
} wazmrt_valkind_t;

typedef struct {
    wazmrt_valkind_t kind;
    union {
        int32_t  i32;
        int64_t  i64;
        float    f32;
        double   f64;
        uint64_t ref;
        /* EXACTLY the 16 bytes wasm stores in linear memory — little-endian lane order, the
         * layout `v128.store` writes and `v128.load` reads. No lane reinterpretation happens
         * at this boundary, so a host that memcpy's these bytes into its own vector type gets
         * what the guest had. */
        uint8_t  v128[16];
    } of;
} wazmrt_val_t;

/* The kind of an import or export. */
typedef enum {
    WAZMRT_EXTERN_FUNC   = 0,
    WAZMRT_EXTERN_TABLE  = 1,
    WAZMRT_EXTERN_MEMORY = 2,
    WAZMRT_EXTERN_GLOBAL = 3,
    WAZMRT_EXTERN_TAG    = 4
} wazmrt_externkind_t;

/* ---- Config: proposals + resource ceilings --------------------------------------------
 *
 * A config is a template; `wazmrt_engine_new_with_config` copies it. You still own the
 * config afterwards and must delete it.
 */

/* The WebAssembly proposals that can be individually refused. ALL ARE ON BY DEFAULT —
 * wazmrt's stated scope is full browser-standard parity plus memory64.
 *
 * ⚠️ A TOGGLE HERE GATES FOR REAL. A disabled proposal makes a module INVALID: it is refused by
 * `wazmrt_module_new` AND `wazmrt_module_validate` — wholly, before anything executes, never
 * part-way through. The error names the proposal, so "you disabled gc" reaches you rather than a
 * type error inside a feature you never wanted to allow.
 *
 * Gating looks at the module's TYPES as well as its code, because a module can need a proposal
 * without ever executing one of its instructions — a `v128` parameter needs SIMD even if nothing
 * in the body is a SIMD op.
 *
 * ⚠️ A PROPOSAL LAYERED ON ANOTHER MUST BE DISABLED WITH IT. Turning off `SIMD` while
 * `RELAXED_SIMD` stays on is an incoherent config and `wazmrt_engine_new_with_config` reports it
 * rather than quietly repairing it — silently enabling a dependency would accept modules you
 * meant to refuse. The layering is noted per entry below.
 *
 * There is deliberately NO tail-call entry: `return_call` / `return_call_indirect` are not
 * in wazmrt's implemented set, so a toggle for them would gate nothing. `return_call_ref`
 * belongs to function-references and is covered by that flag.
 */
typedef enum {
    WAZMRT_FEATURE_SIGN_EXTENSION            = 0,
    WAZMRT_FEATURE_SATURATING_FLOAT_TO_INT   = 1,
    WAZMRT_FEATURE_MULTI_VALUE               = 2,
    WAZMRT_FEATURE_REFERENCE_TYPES           = 3,
    WAZMRT_FEATURE_BULK_MEMORY               = 4,
    WAZMRT_FEATURE_EXTENDED_CONST            = 5,
    WAZMRT_FEATURE_SIMD                      = 6,
    WAZMRT_FEATURE_RELAXED_SIMD              = 7,   /* requires SIMD                */
    WAZMRT_FEATURE_THREADS                   = 8,
    WAZMRT_FEATURE_MULTI_MEMORY              = 9,
    WAZMRT_FEATURE_MEMORY64                  = 10,
    WAZMRT_FEATURE_FUNCTION_REFERENCES       = 11,  /* requires REFERENCE_TYPES     */
    WAZMRT_FEATURE_GC                        = 12,  /* requires FUNCTION_REFERENCES */
    WAZMRT_FEATURE_EXCEPTIONS                = 13   /* requires REFERENCE_TYPES     */
} wazmrt_feature_t;

wazmrt_config_t *wazmrt_config_new(void);
void wazmrt_config_delete(wazmrt_config_t *);

/* One setter rather than fourteen: adding a proposal later must not add a symbol, and the
 * enum keeps the exported surface small (a stated goal). False for an unrecognised feature. */
bool wazmrt_config_set_feature(wazmrt_config_t *, wazmrt_feature_t, bool enabled);
/* Reads back what is actually set, so you can confirm a restriction took effect. */
bool wazmrt_config_get_feature(const wazmrt_config_t *, wazmrt_feature_t, bool *out);

/* Turn every proposal on (the default) or off (WebAssembly 1.0 only). */
void wazmrt_config_all_features(wazmrt_config_t *, bool enabled);

/* Resource ceilings. Each is a CEILING, not a reservation: raising one costs nothing until a
 * guest actually asks for it — wazmrt's linear memory is lazily paged. Passing 0 leaves the
 * current value unchanged.
 *
 * All five are ENFORCED, and not only at instantiation: the interpreter re-checks the memory and
 * table budgets in `memory.grow` and `table.grow`, so a guest cannot climb past them at run
 * time. A value larger than this machine can represent is treated as "no limit" rather than
 * being truncated into a tighter cap than you asked for. */
void wazmrt_config_set_max_memory_bytes(wazmrt_config_t *, uint64_t);
void wazmrt_config_set_max_table_elements(wazmrt_config_t *, uint64_t);
void wazmrt_config_set_max_gc_objects(wazmrt_config_t *, uint64_t);
void wazmrt_config_set_max_exception_boxes(wazmrt_config_t *, uint64_t);

/* Guest call depth before the engine reports "call stack exhausted". Default 512.
 *
 * WORTH SETTING IF YOU LINK A DEBUG BUILD. The interpreter recurses on the host stack, and an
 * un-inlined debug frame is large enough that the default can exhaust an 8 MiB thread stack
 * before the limit fires. Release builds are fine at the default, which is why the default is
 * not simply lowered. */
void wazmrt_config_set_max_call_depth(wazmrt_config_t *, uint32_t);

/* ---- Engine ---------------------------------------------------------------------------
 * Holds the configuration shared by the stores made from it. Must outlive them.
 */
wazmrt_engine_t *wazmrt_engine_new(void);                 /* defaults: every proposal on */

/* Returns NULL and sets *error if the config is incoherent — a proposal enabled without one
 * it is layered on (GC without function-references, relaxed SIMD without SIMD). Such a config
 * is REPORTED rather than quietly repaired: silently enabling a dependency would accept
 * modules you meant to refuse. You still own `cfg`. */
wazmrt_engine_t *wazmrt_engine_new_with_config(const wazmrt_config_t *cfg,
                                               wazmrt_error_t **error);
void wazmrt_engine_delete(wazmrt_engine_t *);

/* ---- Store ----------------------------------------------------------------------------
 * Owns instances and every memory, table and global they use. Instances in ONE store can
 * import from each other and genuinely share those resources; instances in different stores
 * are isolated. Must not outlive its engine.
 */
wazmrt_store_t *wazmrt_store_new(wazmrt_engine_t *);
void wazmrt_store_delete(wazmrt_store_t *);

/* ---- Module: compile, validate, introspect -------------------------------------------- */

/* Decode and validate `bytes`. Returns NULL on success, writing the module to *out; on
 * failure returns an error and leaves *out untouched. The bytes are not retained.
 *
 * VALIDATION IS NOT OPTIONAL on any path that can execute. A runtime that runs an invalid
 * module is over-permissive, not lenient — and an invalid module that is merely wrong (rather
 * than memory-unsafe) runs and prints a plausible wrong answer. */
wazmrt_error_t *wazmrt_module_new(wazmrt_engine_t *, const uint8_t *bytes, size_t len,
                                  wazmrt_module_t **out);

/* Would `wazmrt_module_new` succeed? No allocation, no module produced. */
bool wazmrt_module_validate(wazmrt_engine_t *, const uint8_t *bytes, size_t len);

void wazmrt_module_delete(wazmrt_module_t *);

/* Exports. `name` is borrowed for the module's lifetime and is NOT guaranteed
 * NUL-terminated — use `*name_len_out`. False if `i` is out of range. */
size_t wazmrt_module_export_count(const wazmrt_module_t *);
bool   wazmrt_module_export(const wazmrt_module_t *, size_t i,
                            const char **name_out, size_t *name_len_out,
                            wazmrt_externkind_t *kind_out);

/* Imports, in DECLARATION ORDER — the order a linker must satisfy them in. */
size_t wazmrt_module_import_count(const wazmrt_module_t *);
bool   wazmrt_module_import(const wazmrt_module_t *, size_t i,
                            const char **module_out, size_t *module_len_out,
                            const char **name_out, size_t *name_len_out,
                            wazmrt_externkind_t *kind_out);

/* ---- WebAssembly text (`.wat`) ---------------------------------------------------------
 *
 * wazmrt assembles the text format itself, so an embedder can run a `.wat` with no external
 * toolchain — no `wat2wasm` process, no temporary file, no build step.
 *
 * ⚠️ WHERE THE SAVING IS. This removes a PIPELINE, not decode time. Parsing text costs more
 * per module than decoding a binary, so a module you run repeatedly is still better assembled
 * once and cached as `.wasm` (which is what `wazmrt_wat_to_wasm` is for). The win is the
 * edit-run loop, where the module changes every time and the conversion step is pure latency.
 */

/* Assemble text, then decode and validate the result — `wazmrt_module_new` for `.wat`. */
wazmrt_error_t *wazmrt_module_new_wat(wazmrt_engine_t *, const char *text, size_t len,
                                      wazmrt_module_t **out);

/* Assemble text to a binary and hand it back. On success returns NULL and writes an owned
 * buffer to *out / *out_len; free it with `wazmrt_bytes_delete`. Use this to cache the
 * binary, or to hand it to something else that wants `.wasm`. */
wazmrt_error_t *wazmrt_wat_to_wasm(const char *text, size_t len,
                                   uint8_t **out, size_t *out_len);

/* Free a buffer produced by this library. Only ever call it on such a buffer. */
void wazmrt_bytes_delete(uint8_t *bytes, size_t len);

/* ---- Function types -------------------------------------------------------------------- */
wazmrt_functype_t *wazmrt_functype_new(const wazmrt_valkind_t *params, size_t nparams,
                                       const wazmrt_valkind_t *results, size_t nresults);
void   wazmrt_functype_delete(wazmrt_functype_t *);
size_t wazmrt_functype_param_count(const wazmrt_functype_t *);
size_t wazmrt_functype_result_count(const wazmrt_functype_t *);
bool   wazmrt_functype_param(const wazmrt_functype_t *, size_t i, wazmrt_valkind_t *out);
bool   wazmrt_functype_result(const wazmrt_functype_t *, size_t i, wazmrt_valkind_t *out);

/* ---- Host callbacks --------------------------------------------------------------------
 *
 * CALLER-BASED, which is the load-bearing difference from the standard wasm-c-api: that
 * API's callback gets no handle to the caller's memory, and essentially every real host
 * import needs to read guest memory and return a value.
 *
 * Return NULL for success, or a `wazmrt_trap_t *` to trap the guest (ownership transfers to
 * the engine — do not delete it). Write exactly `nresults` values into `results`.
 *
 * `caller` is valid ONLY for the duration of the call. Storing it and using it later is
 * undefined behaviour.
 */
typedef wazmrt_trap_t *(*wazmrt_func_callback_t)(
    void *env, wazmrt_caller_t *caller,
    const wazmrt_val_t *args, size_t nargs,
    wazmrt_val_t *results, size_t nresults);

/* The calling instance's exported memory, by name (conventionally "memory"). False if there
 * is no such export. */
bool wazmrt_caller_get_memory(wazmrt_caller_t *, const char *name, wazmrt_memory_t *out);

/* Bounds-checked access to the caller's memory without needing a handle first — the common
 * case inside a callback. False if the range is out of bounds; nothing is copied. */
bool   wazmrt_caller_read(wazmrt_caller_t *, uint64_t offset, void *dst, size_t n);
bool   wazmrt_caller_write(wazmrt_caller_t *, uint64_t offset, const void *src, size_t n);
size_t wazmrt_caller_memory_size(wazmrt_caller_t *);

/* ---- Linker ----------------------------------------------------------------------------
 *
 * Resolves a module's imports BY NAME, walking them in declaration order. Reusable: define a
 * host surface once and instantiate many modules against it. Must not outlive its engine.
 */
wazmrt_linker_t *wazmrt_linker_new(wazmrt_engine_t *);
void wazmrt_linker_delete(wazmrt_linker_t *);

/* Define `module`.`name` as a host function. The linker copies the name strings and takes
 * ownership of nothing else; `env` is passed to every call, and `env_finalizer` (may be NULL)
 * runs when the linker is deleted or the name redefined. Redefining replaces.
 *
 * ✅ The type you declare here is CHECKED against the type the guest declares for that import,
 * at link time, and a disagreement fails `wazmrt_linker_instantiate` naming the import. Binding
 * a mismatched callback would have it read arguments that were never passed — reachable from a
 * four-line module — so this is refused rather than trusted. */
wazmrt_error_t *wazmrt_linker_define_func(wazmrt_linker_t *,
                                          const char *module, const char *name,
                                          const wazmrt_functype_t *,
                                          wazmrt_func_callback_t, void *env,
                                          void (*env_finalizer)(void *env));

wazmrt_error_t *wazmrt_linker_define_global(wazmrt_linker_t *,
                                            const char *module, const char *name,
                                            wazmrt_val_t value);

/* Publish every export of an already-instantiated module under the namespace `module`, so
 * later modules can import from it. The callee runs against ITS OWN instance, so it sees the
 * exporter's memory and globals. `instance` must belong to the store you later instantiate
 * into. */
wazmrt_error_t *wazmrt_linker_define_instance(wazmrt_linker_t *, const char *module,
                                              wazmrt_instance_t instance);

/* Provide WASI preview 1, using `cfg` (which the linker copies; you still own it). */
wazmrt_error_t *wazmrt_linker_define_wasi(wazmrt_linker_t *, const wazmrt_wasi_config_t *cfg);

/* Back every otherwise-unsatisfied FUNCTION import with a stub that traps if called.
 *
 * Useful because a module often declares more than it uses. The cost is real: with this set,
 * a typo'd import name is no longer a link-time error but a runtime surprise. Prefer explicit
 * definitions. */
wazmrt_error_t *wazmrt_linker_define_unknown_imports_as_traps(wazmrt_linker_t *);

/* Resolve and instantiate into `store`, running the module's start function if it has one. A
 * reactor's `_initialize` is NOT called — see `wazmrt_instance_initialize`.
 *
 * Returns an error for a link failure (naming the unresolved import). If the start function
 * traps, returns NULL and sets *trap_out. Check both. */
wazmrt_error_t *wazmrt_linker_instantiate(wazmrt_linker_t *, wazmrt_store_t *,
                                          const wazmrt_module_t *,
                                          wazmrt_instance_t *out,
                                          wazmrt_trap_t **trap_out);

/* ---- WASI preview 1 --------------------------------------------------------------------
 *
 * A guest reaches NOTHING it was not explicitly granted. With no preopened directory every
 * path call fails with BADF — there is no implicit working directory.
 */
wazmrt_wasi_config_t *wazmrt_wasi_config_new(void);
void wazmrt_wasi_config_delete(wazmrt_wasi_config_t *);

void wazmrt_wasi_config_inherit_stdout(wazmrt_wasi_config_t *);
void wazmrt_wasi_config_inherit_stderr(wazmrt_wasi_config_t *);
void wazmrt_wasi_config_inherit_stdin(wazmrt_wasi_config_t *);

/* argv/envp as NUL-terminated strings. Copied. */
void wazmrt_wasi_config_set_args(wazmrt_wasi_config_t *, const char *const *argv, size_t n);
void wazmrt_wasi_config_set_env(wazmrt_wasi_config_t *,
                                const char *const *names, const char *const *values, size_t n);

/* Grant `host_path`, visible to the guest as `guest_path`. Returns an error if the directory
 * cannot be opened.
 *
 * `read_only` narrows the rights the guest receives and propagates to the whole subtree.
 * Symlink CREATION is denied on every preopen unless `allow_symlink` is set: composing
 * modules over shared memory is the runtime's job, so a workload never needs new links on
 * disk, and denying creation shrinks what an external racer can repoint. Following a
 * PRE-EXISTING symlink is unaffected — that needs only `path_open`, which every grant keeps. */
wazmrt_error_t *wazmrt_wasi_config_preopen_dir(wazmrt_wasi_config_t *,
                                               const char *host_path, const char *guest_path,
                                               bool read_only, bool allow_symlink);

/* The exit code a guest passed to `proc_exit`, if it called it. Read after instantiate or a
 * call returns. */
bool wazmrt_wasi_exit_code(const wazmrt_linker_t *, int32_t *out);

/* ---- Instance exports ------------------------------------------------------------------ */
bool wazmrt_instance_get_func(wazmrt_store_t *, wazmrt_instance_t, const char *name,
                              wazmrt_func_t *out);
bool wazmrt_instance_get_memory(wazmrt_store_t *, wazmrt_instance_t, const char *name,
                                wazmrt_memory_t *out);
bool wazmrt_instance_get_global(wazmrt_store_t *, wazmrt_instance_t, const char *name,
                                wazmrt_global_t *out);

/* The reactor convention: call `_initialize` once after instantiating, if it is exported. A
 * no-op returning NULL when it is not. */
wazmrt_error_t *wazmrt_instance_initialize(wazmrt_store_t *, wazmrt_instance_t,
                                           wazmrt_trap_t **trap_out);

/* ---- Calling exports ------------------------------------------------------------------- */

/* The function's signature. Owned by the caller; delete it. NULL if the handle is invalid. */
wazmrt_functype_t *wazmrt_func_type(const wazmrt_store_t *, wazmrt_func_t);

/* Call it. `args`/`results` are caller-provided buffers; `nresults` must match the function's
 * result count exactly.
 *
 * Returns an error for MISUSE (bad handle, wrong arity, a type the boundary cannot carry).
 * Returns NULL and sets *trap_out if the GUEST trapped. Returns NULL with *trap_out untouched
 * on success. */
wazmrt_error_t *wazmrt_func_call(wazmrt_store_t *, wazmrt_func_t,
                                 const wazmrt_val_t *args, size_t nargs,
                                 wazmrt_val_t *results, size_t nresults,
                                 wazmrt_trap_t **trap_out);

/* ---- Linear memory ----------------------------------------------------------------------
 *
 * Two ways in. The raw view is the fast path embedders marshalling by hand want; the checked
 * copies are there when you would rather not reason about the invalidation rule.
 */

/* Raw view of guest memory.
 *
 * INVALIDATION — read this. The returned pointer is invalidated by anything that can grow or
 * replace the memory: `wazmrt_func_call`, `wazmrt_instance_initialize`,
 * `wazmrt_linker_instantiate` on the same store, and a guest `memory.grow` inside any of
 * them. Re-fetch after each; never cache it across a call. NULL for an invalid handle. */
uint8_t *wazmrt_memory_data(wazmrt_store_t *, wazmrt_memory_t);
size_t   wazmrt_memory_data_size(const wazmrt_store_t *, wazmrt_memory_t);
uint64_t wazmrt_memory_size_pages(const wazmrt_store_t *, wazmrt_memory_t);

/* Bounds-checked copies. False if the range is out of bounds or the handle is invalid; on
 * false nothing is copied. No pointer escapes, so there is no invalidation rule to get
 * wrong. */
bool wazmrt_memory_read(const wazmrt_store_t *, wazmrt_memory_t,
                        uint64_t offset, void *dst, size_t n);
bool wazmrt_memory_write(wazmrt_store_t *, wazmrt_memory_t,
                         uint64_t offset, const void *src, size_t n);

/* ---- Globals ----------------------------------------------------------------------------
 * A snapshot of the value. False for an invalid handle or a type the boundary cannot carry.
 */
bool wazmrt_global_get(const wazmrt_store_t *, wazmrt_global_t, wazmrt_val_t *out);

/* ---- Traps ------------------------------------------------------------------------------ */

/* Create a trap to return from a host callback. `message` is copied and may be NULL.
 *
 * Returning one from a `wazmrt_func_callback_t` transfers ownership to the engine — do NOT
 * delete it yourself. Delete only a trap the engine handed to YOU through a `trap_out`
 * parameter. */
wazmrt_trap_t *wazmrt_trap_new(const char *message);

/* NUL-terminated, borrowed until the trap is deleted. */
const char *wazmrt_trap_message(const wazmrt_trap_t *);
void        wazmrt_trap_delete(wazmrt_trap_t *);

/* Stack frames, innermost first. Snapshotted when the trap was created, so they stay valid
 * for as long as the trap does — you may keep it across further calls.
 *
 * A trap raised by one of YOUR host callbacks reports zero frames: it did not come out of
 * guest code, so there is no guest stack to show. `wazmrt_trap_message` always has the reason.
 *
 * `func_index_out` indexes the instance's function space, imports included — the same
 * numbering `ref.func` and the name section use.
 *
 * `offset_out` is the byte offset of the trapping instruction FROM THE START OF THE MODULE,
 * which is what `wasm-objdump` prints, so it can be looked up with no rebasing. ⚠️ Do not
 * "improve" this to a body-relative offset: the whole value of the number is that it can be
 * compared against another tool's output directly.
 *
 * `name_out` receives the function's name from the name section, or NULL if the guest was
 * built stripped. Borrowed until the trap is deleted.
 *
 * Every out-parameter is optional — pass NULL for any you do not want. `wazmrt_trap_frame`
 * returns false, writing nothing, for an index at or past the count. */
size_t wazmrt_trap_frame_count(const wazmrt_trap_t *);
bool   wazmrt_trap_frame(const wazmrt_trap_t *, size_t i,
                         uint32_t *func_index_out, uint32_t *offset_out,
                         const char **name_out);

/* ---- Errors ------------------------------------------------------------------------------ */
const char *wazmrt_error_message(const wazmrt_error_t *);
void        wazmrt_error_delete(wazmrt_error_t *);

#ifdef __cplusplus
} /* extern "C" */
#endif
#endif /* WAZMRT_H */
