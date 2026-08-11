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

    /* But a restriction this build cannot apply is still refused, not silently dropped. */
    cfg = wazmrt_config_new();
    wazmrt_config_all_features(cfg, false);
    cerr = NULL;
    wazmrt_engine_t *bad = wazmrt_engine_new_with_config(cfg, &cerr);
    check(bad == NULL && cerr != NULL, "disabling proposals is refused (no gating yet)");
    if (cerr) wazmrt_error_delete(cerr);
    wazmrt_config_delete(cfg);

    /* Disabling a proposal is refused rather than pretended. */
    cfg = wazmrt_config_new();
    check(!wazmrt_config_set_feature(cfg, WAZMRT_FEATURE_SIMD, false), "set_feature(false) is refused");
    check(wazmrt_config_set_feature(cfg, WAZMRT_FEATURE_SIMD, true), "set_feature(true) succeeds");
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
