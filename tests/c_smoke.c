/*
 * C smoke test for the wasm-c-api surface wazmrt implements today.
 * Exercises the ABI from C exactly as a universalWasmLoader-* port would:
 * engine/store, module decode+validate, and import/export introspection.
 *
 * Build with zig cc (no MSVC needed), e.g.:
 *   zig build-lib src/wasm_c_api.zig -target x86_64-windows-gnu -O ReleaseSmall \
 *     -femit-bin=wazmrt.lib
 *   zig cc -target x86_64-windows-gnu -DLIBWASM_STATIC \
 *     -Iinclude -Ithird_party/wasm-c-api/include \
 *     tests/c_smoke.c wazmrt.lib -o smoke.exe
 */
/* Compiled with -DLIBWASM_STATIC (wazmrt ships a static lib). */
#include "wazmrt.h"

#include <stdio.h>
#include <string.h>

int main(void) {
    int failures = 0;

    wasm_engine_t *engine = wasm_engine_new();
    wasm_store_t *store = wasm_store_new(engine);
    if (!engine || !store) {
        printf("FAIL: engine/store creation\n");
        return 1;
    }

    /*
     * A real module:
     *   (type (func (param i32 i32) (result i32)))
     *   (import "env" "add" (func (type 0)))
     *   (func (type 0))               ; defined func, index 1
     *   (export "run" (func 1))
     */
    const unsigned char mod[] = {
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
        0x02, 0x0b, 0x01, 0x03, 'e', 'n', 'v', 0x03, 'a', 'd', 'd', 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x07, 0x01, 0x03, 'r', 'u', 'n', 0x00, 0x01,
    };
    wasm_byte_vec_t binary;
    wasm_byte_vec_new_uninitialized(&binary, sizeof(mod));
    memcpy(binary.data, mod, sizeof(mod));

    bool valid = wasm_module_validate(store, &binary);
    printf("validate(good):  %s\n", valid ? "true" : "false");
    if (!valid) failures++;

    wasm_module_t *module = wasm_module_new(store, &binary);
    printf("module_new:      %s\n", module ? "ok" : "null");
    if (!module) {
        failures++;
    } else {
        wasm_importtype_vec_t imports;
        wasm_module_imports(module, &imports);
        printf("imports:         %zu\n", imports.size);
        if (imports.size != 1) failures++;
        for (size_t i = 0; i < imports.size; i++) {
            const wasm_name_t *m = wasm_importtype_module(imports.data[i]);
            const wasm_name_t *n = wasm_importtype_name(imports.data[i]);
            const wasm_externtype_t *et = wasm_importtype_type(imports.data[i]);
            printf("  %.*s.%.*s  externkind=%d\n",
                   (int)m->size, m->data, (int)n->size, n->data,
                   wasm_externtype_kind(et));
        }

        wasm_exporttype_vec_t exports;
        wasm_module_exports(module, &exports);
        printf("exports:         %zu\n", exports.size);
        if (exports.size != 1) failures++;
        for (size_t i = 0; i < exports.size; i++) {
            const wasm_name_t *n = wasm_exporttype_name(exports.data[i]);
            const wasm_externtype_t *et = wasm_exporttype_type(exports.data[i]);
            printf("  %.*s  externkind=%d", (int)n->size, n->data,
                   wasm_externtype_kind(et));
            if (wasm_externtype_kind(et) == WASM_EXTERN_FUNC) {
                const wasm_functype_t *ft = wasm_externtype_as_functype_const(et);
                const wasm_valtype_vec_t *ps = wasm_functype_params(ft);
                const wasm_valtype_vec_t *rs = wasm_functype_results(ft);
                printf("  params=%zu results=%zu", ps->size, rs->size);
                if (ps->size != 2 || rs->size != 1) failures++;
            }
            printf("\n");
        }

        wasm_importtype_vec_delete(&imports);
        wasm_exporttype_vec_delete(&exports);
    }

    /*
     * Instantiate + call a self-contained module (no imports):
     *   (func (export "add") (param i32 i32) (result i32)
     *     local.get 0  local.get 1  i32.add)
     */
    const unsigned char addmod[] = {
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, /* type (i32,i32)->i32 */
        0x03, 0x02, 0x01, 0x00,                               /* func 0 : type 0     */
        0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00,    /* export "add" func 0 */
        /* code: 1 body, size 7 = locals(00) + local.get 0, local.get 1, i32.add, end */
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    };
    wasm_byte_vec_t addbin;
    wasm_byte_vec_new(&addbin, sizeof(addmod), (const wasm_byte_t *)addmod);
    wasm_module_t *addmodule = wasm_module_new(store, &addbin);
    if (!addmodule) {
        printf("FAIL: add module decode\n");
        failures++;
    } else {
        wasm_trap_t *trap = NULL;
        wasm_extern_vec_t noimports;
        wasm_extern_vec_new_empty(&noimports);
        wasm_instance_t *inst = wasm_instance_new(store, addmodule, &noimports, &trap);
        printf("instance_new:    %s\n", inst ? "ok" : "null");
        if (!inst) {
            failures++;
        } else {
            wasm_extern_vec_t exps;
            wasm_instance_exports(inst, &exps);
            printf("inst_exports:    %zu\n", exps.size);
            if (exps.size != 1) failures++;

            wasm_func_t *add = wasm_extern_as_func(exps.data[0]);
            printf("as_func:         %s (params=%zu results=%zu)\n",
                   add ? "ok" : "null",
                   add ? wasm_func_param_arity(add) : 0,
                   add ? wasm_func_result_arity(add) : 0);
            if (!add || wasm_func_param_arity(add) != 2 || wasm_func_result_arity(add) != 1)
                failures++;

            wasm_val_t argsv[2];
            argsv[0].kind = WASM_I32; argsv[0].of.i32 = 40;
            argsv[1].kind = WASM_I32; argsv[1].of.i32 = 2;
            wasm_val_vec_t call_args, call_results;
            wasm_val_vec_new(&call_args, 2, argsv);
            wasm_val_vec_new_uninitialized(&call_results, 1);

            wasm_trap_t *ctrap = wasm_func_call(add, &call_args, &call_results);
            if (ctrap) {
                wasm_message_t msg;
                wasm_trap_message(ctrap, &msg);
                printf("FAIL: call trapped: %s\n", msg.data ? (const char *)msg.data : "?");
                wasm_byte_vec_delete(&msg);
                wasm_trap_delete(ctrap);
                failures++;
            } else {
                int32_t r = call_results.data[0].of.i32;
                printf("add(40, 2):      %d\n", r);
                if (r != 42) failures++;
            }

            wasm_val_vec_delete(&call_args);
            wasm_val_vec_delete(&call_results);
            wasm_extern_vec_delete(&exps);
            wasm_instance_delete(inst);
        }
        wasm_extern_vec_delete(&noimports);
        wasm_module_delete(addmodule);
    }
    wasm_byte_vec_delete(&addbin);

    /* Negative: a bad magic must fail to validate. */
    const unsigned char bad[] = { 'n', 'o', 'p', 'e', 1, 0, 0, 0 };
    wasm_byte_vec_t badv;
    wasm_byte_vec_new(&badv, sizeof(bad), (const wasm_byte_t *)bad);
    bool bad_valid = wasm_module_validate(store, &badv);
    printf("validate(bad):   %s\n", bad_valid ? "true" : "false");
    if (bad_valid) failures++;

    printf("abi_version:     %u\n", wazmrt_abi_version());
    printf("version:         %s\n", wazmrt_version_string());

    wasm_module_delete(module);
    wasm_byte_vec_delete(&binary);
    wasm_byte_vec_delete(&badv);
    wasm_store_delete(store);
    wasm_engine_delete(engine);

    printf("%s\n", failures == 0 ? "OK" : "FAILED");
    return failures == 0 ? 0 : 1;
}
