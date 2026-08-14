/*
 * capi_smoke.c — drive the ABI-2 surface from C, exactly as an embedder would.
 *
 * The Zig tests in `src/capi.zig` run these same entry points under an allocator that fails on
 * double-free and leaks, which is the stronger check. This file answers a different question:
 * does the published HEADER actually describe a usable API from a C compiler's point of view —
 * types, const-ness, calling convention, and the symbols really being there at link time.
 *
 * ⚠️ This cannot replace the Zig tests. On the real allocator a double free silently corrupts the
 * freelist and a smoke test still prints OK. It did exactly that once, which is how #21's four
 * bugs shipped.
 */
#include "wazmrt.h"

#include <stdio.h>
#include <string.h>

/* Defined in tests/wazmrt_abi_symbols.c — the link-time completeness gate. */
extern const void *const wazmrt_abi_symbols[];
extern const size_t wazmrt_abi_symbol_count;

static int failures = 0;

static void check(int ok, const char *what) {
    if (ok) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        failures++;
    }
}

/* A host import that reads guest memory through the caller — the loader pattern. */
static wazmrt_trap_t *peek(void *env, wazmrt_caller_t *caller,
                           const wazmrt_val_t *args, size_t nargs,
                           wazmrt_val_t *results, size_t nresults) {
    (void)env;
    if (nargs != 1 || nresults != 1) return wazmrt_trap_new("peek: bad arity");
    uint32_t word = 0;
    if (!wazmrt_caller_read(caller, (uint64_t)args[0].of.i32, &word, sizeof word))
        return wazmrt_trap_new("peek: out of bounds");
    results[0].kind = WAZMRT_I32;
    results[0].of.i32 = (int32_t)word;
    return NULL;
}

static const char *const kWat =
    "(module\n"
    "  (import \"env\" \"peek\" (func $peek (param i32) (result i32)))\n"
    "  (memory (export \"mem\") 1)\n"
    "  (func (export \"run\") (result i32) i32.const 4 call $peek))\n";

int main(void) {
    printf("wazmrt C ABI smoke\n");
    printf("  abi_version: %u (header says %u)\n", wazmrt_abi_version(), WAZMRT_ABI_VERSION);
    check(wazmrt_abi_version() == WAZMRT_ABI_VERSION, "header and library agree on the ABI version");
    printf("  version:     %s\n", wazmrt_version_string());
    printf("  symbols:     %zu declared, all defined\n", wazmrt_abi_symbol_count);
    check(wazmrt_abi_symbol_count > 0, "symbol table is non-empty");

    wazmrt_engine_t *engine = wazmrt_engine_new();
    check(engine != NULL, "engine_new");
    wazmrt_store_t *store = wazmrt_store_new(engine);
    check(store != NULL, "store_new");
    wazmrt_linker_t *linker = wazmrt_linker_new(engine);
    check(linker != NULL, "linker_new");

    /* Define the host import, with the type the guest declares. */
    wazmrt_valkind_t params[1] = {WAZMRT_I32};
    wazmrt_valkind_t results[1] = {WAZMRT_I32};
    wazmrt_functype_t *ft = wazmrt_functype_new(params, 1, results, 1);
    check(ft != NULL, "functype_new");
    wazmrt_error_t *err = wazmrt_linker_define_func(linker, "env", "peek", ft, peek, NULL, NULL);
    check(err == NULL, "linker_define_func");
    if (err) wazmrt_error_delete(err);

    /* The differentiator: assemble and run `.wat` with no external toolchain. */
    wazmrt_module_t *mod = NULL;
    err = wazmrt_module_new_wat(engine, kWat, strlen(kWat), &mod);
    if (err) {
        printf("  FAIL  module_new_wat: %s\n", wazmrt_error_message(err));
        wazmrt_error_delete(err);
        failures++;
    } else {
        check(mod != NULL, "module_new_wat (text assembled, decoded and validated)");
    }

    if (mod) {
        check(wazmrt_module_import_count(mod) == 1, "module_import_count");
        check(wazmrt_module_export_count(mod) == 2, "module_export_count");

        wazmrt_instance_t inst;
        wazmrt_trap_t *trap = NULL;
        err = wazmrt_linker_instantiate(linker, store, mod, &inst, &trap);
        check(err == NULL && trap == NULL, "linker_instantiate");
        if (err) wazmrt_error_delete(err);

        check(wazmrt_instance_is_valid(store, inst), "instance handle is valid");

        wazmrt_memory_t mem;
        check(wazmrt_instance_get_memory(store, inst, "mem", &mem), "instance_get_memory");
        check(wazmrt_memory_size_pages(store, mem) == 1, "memory_size_pages");

        uint32_t planted = 0xdeadbeefu;
        check(wazmrt_memory_write(store, mem, 4, &planted, sizeof planted), "memory_write");

        wazmrt_func_t fn;
        check(wazmrt_instance_get_func(store, inst, "run", &fn), "instance_get_func");
        wazmrt_functype_t *got = wazmrt_func_type(store, fn);
        check(got != NULL && wazmrt_functype_result_count(got) == 1, "func_type");
        if (got) wazmrt_functype_delete(got);

        wazmrt_val_t out[1];
        err = wazmrt_func_call(store, fn, NULL, 0, out, 1, &trap);
        check(err == NULL && trap == NULL, "func_call");
        if (err) wazmrt_error_delete(err);
        check(out[0].kind == WAZMRT_I32 && (uint32_t)out[0].of.i32 == 0xdeadbeefu,
              "host callback read guest memory through the caller");

        /* A handle from this store must not be honoured by a different one. */
        wazmrt_store_t *other = wazmrt_store_new(engine);
        check(!wazmrt_func_is_valid(other, fn), "a handle is rejected by a foreign store");
        wazmrt_store_delete(other);

        wazmrt_module_delete(mod);
    }

    /* Every ceiling is enforced now, so a config that sets them must SUCCEED. */
    wazmrt_config_t *cfg = wazmrt_config_new();
    wazmrt_config_set_max_memory_bytes(cfg, 1u << 20);
    wazmrt_config_set_max_call_depth(cfg, 64);
    wazmrt_config_set_max_gc_objects(cfg, 1000);
    wazmrt_config_set_max_exception_boxes(cfg, 1000);
    wazmrt_error_t *cerr = NULL;
    wazmrt_engine_t *capped = wazmrt_engine_new_with_config(cfg, &cerr);
    check(capped != NULL && cerr == NULL, "all five resource ceilings are accepted");
    if (cerr) wazmrt_error_delete(cerr);
    if (capped) wazmrt_engine_delete(capped);
    wazmrt_config_delete(cfg);

    /* A disabled proposal makes a module INVALID. `(module (type (func (param v128))))` needs
     * SIMD to be legal, and needs nothing else — so it is the smallest honest probe. */
    static const uint8_t kV128Type[] = {
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7b, 0x00,
    };
    cfg = wazmrt_config_new();
    check(wazmrt_config_set_feature(cfg, WAZMRT_FEATURE_SIMD, false), "set_feature(false) is honoured");
    /* Relaxed SIMD rests on SIMD, so it has to go too — the engine reports an incoherent
     * config rather than quietly repairing it. */
    wazmrt_config_set_feature(cfg, WAZMRT_FEATURE_RELAXED_SIMD, false);
    bool simd_on = true;
    wazmrt_config_get_feature(cfg, WAZMRT_FEATURE_SIMD, &simd_on);
    check(!simd_on, "get_feature reports it is really off");

    cerr = NULL;
    wazmrt_engine_t *nosimd = wazmrt_engine_new_with_config(cfg, &cerr);
    check(nosimd != NULL && cerr == NULL, "a coherent restricted config builds an engine");
    if (cerr) wazmrt_error_delete(cerr);
    wazmrt_config_delete(cfg);

    if (nosimd) {
        wazmrt_module_t *m = NULL;
        wazmrt_error_t *gerr = wazmrt_module_new(nosimd, kV128Type, sizeof kV128Type, &m);
        check(gerr != NULL, "a module needing a disabled proposal is refused");
        if (gerr) wazmrt_error_delete(gerr);
        check(!wazmrt_module_validate(nosimd, kV128Type, sizeof kV128Type),
              "module_validate agrees with module_new about gating");
        /* No false positives: a plain 1.0 module still loads on the restricted engine.
         * `(module (func (export "answer") (result i32) i32.const 42))` — nothing but core. */
        static const uint8_t kPlain[] = {
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
            0x03, 0x02, 0x01, 0x00,
            0x07, 0x0a, 0x01, 0x06, 'a', 'n', 's', 'w', 'e', 'r', 0x00, 0x00,
            0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
        };
        wazmrt_module_t *plain = NULL;
        gerr = wazmrt_module_new(nosimd, kPlain, sizeof kPlain, &plain);
        check(gerr == NULL && plain != NULL, "a plain module still loads with SIMD disabled");
        if (gerr) wazmrt_error_delete(gerr);
        if (plain) wazmrt_module_delete(plain);
        wazmrt_engine_delete(nosimd);
    }

    /* An incoherent config is reported, not repaired. */
    cfg = wazmrt_config_new();
    wazmrt_config_set_feature(cfg, WAZMRT_FEATURE_FUNCTION_REFERENCES, false);
    cerr = NULL;
    wazmrt_engine_t *bad = wazmrt_engine_new_with_config(cfg, &cerr);
    check(bad == NULL && cerr != NULL, "gc without function-references is refused as incoherent");
    if (cerr) wazmrt_error_delete(cerr);
    wazmrt_config_delete(cfg);

    /* Text -> binary, kept for caching. */
    uint8_t *bin = NULL;
    size_t bin_len = 0;
    err = wazmrt_wat_to_wasm(kWat, strlen(kWat), &bin, &bin_len);
    check(err == NULL && bin != NULL && bin_len > 8, "wat_to_wasm");
    if (err) wazmrt_error_delete(err);
    if (bin) {
        check(bin[0] == 0x00 && bin[1] == 0x61 && bin[2] == 0x73 && bin[3] == 0x6d,
              "assembled bytes start with the wasm magic");
        wazmrt_bytes_delete(bin, bin_len);
    }

    /* ---- Reference values are HANDLES, checked by the store that issued them.
     *
     * This is the surface the .wast corpus can never reach — the R1 lesson, which
     * cost this project a real defect in `define_instance` that no conformance
     * number could have found. A guest returns an externref; the host gets a
     * handle, hands it straight back, and must get the SAME reference. A handle
     * the store never issued must be refused rather than reinterpreted: before
     * boxing, `of.ref` was the interpreter's raw encoding, so an invented value
     * could be read as a GC object, an i31, or null depending on its bits. */
    {
        static const char kRefWat[] =
            "(module (func (export \"id\") (param externref) (result externref) (local.get 0))"
            "        (func (export \"mk\") (result externref) (ref.null extern)))";
        uint8_t *rb = NULL; size_t rb_len = 0;
        wazmrt_error_t *e2 = wazmrt_wat_to_wasm(kRefWat, strlen(kRefWat), &rb, &rb_len);
        check(e2 == NULL, "ref module assembles");
        if (e2) wazmrt_error_delete(e2);
        if (rb) {
            wazmrt_module_t *rm = NULL;
            e2 = wazmrt_module_new(engine, rb, rb_len, &rm);
            check(e2 == NULL && rm != NULL, "ref module loads");
            if (e2) wazmrt_error_delete(e2);
            if (rm) {
                wazmrt_instance_t ri; wazmrt_trap_t *rt = NULL;
                e2 = wazmrt_linker_instantiate(linker, store, rm, &ri, &rt);
                check(e2 == NULL, "ref module instantiates");
                if (e2) wazmrt_error_delete(e2);
                else {
                    /* A null reference is handle 0 — so a zeroed wazmrt_val_t is
                     * null by construction, and 0 is always a valid handle. */
                    wazmrt_func_t mk, id;
                    wazmrt_val_t out = {0}, in = {0};
                    if (wazmrt_instance_get_func(store, ri, "mk", &mk) &&
                        wazmrt_instance_get_func(store, ri, "id", &id)) {
                        e2 = wazmrt_func_call(store, mk, NULL, 0, &out, 1, &rt);
                        check(e2 == NULL && rt == NULL, "mk() returns");
                        if (e2) wazmrt_error_delete(e2);
                        check(out.kind == WAZMRT_EXTERNREF, "mk() returns an externref");
                        check(out.of.ref == 0, "a null reference is handle 0");
                        check(wazmrt_ref_is_valid(store, out.of.ref), "handle 0 is valid");

                        /* Round trip: what the host passes back must come back. */
                        in = out;
                        wazmrt_val_t back = {0};
                        e2 = wazmrt_func_call(store, id, &in, 1, &back, 1, &rt);
                        check(e2 == NULL && rt == NULL, "id(ref) returns");
                        if (e2) wazmrt_error_delete(e2);
                        check(back.of.ref == in.of.ref, "a reference round-trips unchanged");

                        /* An invented handle is REFUSED, not reinterpreted. */
                        check(!wazmrt_ref_is_valid(store, 0xDEADBEEFu),
                              "an invented reference handle is invalid");
                        wazmrt_val_t bogus = {0};
                        bogus.kind = WAZMRT_EXTERNREF;
                        bogus.of.ref = 0xDEADBEEFu;
                        e2 = wazmrt_func_call(store, id, &bogus, 1, &back, 1, &rt);
                        check(e2 != NULL, "calling with an invented reference is refused");
                        if (e2) wazmrt_error_delete(e2);
                    }
                }
                wazmrt_module_delete(rm);
            }
            wazmrt_bytes_delete(rb, rb_len);
        }
    }

    wazmrt_functype_delete(ft);
    wazmrt_linker_delete(linker);
    wazmrt_store_delete(store);
    wazmrt_engine_delete(engine);

    if (failures != 0) {
        printf("FAILED: %d check(s)\n", failures);
        return 1;
    }
    printf("OK\n");
    return 0;
}
