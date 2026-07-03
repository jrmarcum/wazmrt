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
