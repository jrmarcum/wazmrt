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

/* A host function supplied to a module's import: env.add(i32,i32) -> i32. */
static wasm_trap_t *host_add(const wasm_val_vec_t *args, wasm_val_vec_t *results) {
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + args->data[1].of.i32;
    return NULL;
}

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

    /*
     * Host-function import: a module that imports env.add and calls it.
     *   (import "env" "add" (func (param i32 i32) (result i32)))
     *   (func (export "run") (param i32 i32) (result i32)
     *     local.get 0  local.get 1  call 0)
     */
    const unsigned char impmod[] = {
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,          /* type 0 */
        0x02, 0x0b, 0x01, 0x03, 'e','n','v', 0x03, 'a','d','d', 0x00, 0x00, /* import env.add */
        0x03, 0x02, 0x01, 0x00,                                        /* func 1 : type 0 */
        0x07, 0x07, 0x01, 0x03, 'r','u','n', 0x00, 0x01,               /* export "run" func 1 */
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x20, 0x01, 0x10, 0x00, 0x0b, /* code: call 0 */
    };
    wasm_byte_vec_t impbin;
    wasm_byte_vec_new(&impbin, sizeof(impmod), (const wasm_byte_t *)impmod);
    wasm_module_t *impmodule = wasm_module_new(store, &impbin);
    if (!impmodule) {
        printf("FAIL: import module decode\n");
        failures++;
    } else {
        /* Build a functype and the host function backing the import. */
        wasm_valtype_t *pt[2] = { wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32) };
        wasm_valtype_t *rt[1] = { wasm_valtype_new(WASM_I32) };
        wasm_valtype_vec_t pvec, rvec;
        wasm_valtype_vec_new(&pvec, 2, pt);
        wasm_valtype_vec_new(&rvec, 1, rt);
        wasm_functype_t *addtype = wasm_functype_new(&pvec, &rvec);
        wasm_func_t *hostfn = wasm_func_new(store, addtype, host_add);

        wasm_extern_t *import_arr[1] = { wasm_func_as_extern(hostfn) };
        wasm_extern_vec_t import_vec = { 1, import_arr };

        wasm_trap_t *trap = NULL;
        wasm_instance_t *inst = wasm_instance_new(store, impmodule, &import_vec, &trap);
        printf("import_instance: %s\n", inst ? "ok" : "null");
        if (!inst) {
            failures++;
        } else {
            wasm_extern_vec_t exps;
            wasm_instance_exports(inst, &exps);
            wasm_func_t *run = wasm_extern_as_func(exps.data[0]);

            wasm_val_t a[2];
            a[0].kind = WASM_I32; a[0].of.i32 = 40;
            a[1].kind = WASM_I32; a[1].of.i32 = 2;
            wasm_val_vec_t ca, cr;
            wasm_val_vec_new(&ca, 2, a);
            wasm_val_vec_new_uninitialized(&cr, 1);
            wasm_trap_t *rtrap = wasm_func_call(run, &ca, &cr);
            if (rtrap) {
                printf("FAIL: run trapped\n");
                wasm_trap_delete(rtrap);
                failures++;
            } else {
                printf("run(40,2)[host]: %d\n", cr.data[0].of.i32);
                if (cr.data[0].of.i32 != 42) failures++;
            }
            wasm_val_vec_delete(&ca);
            wasm_val_vec_delete(&cr);
            wasm_extern_vec_delete(&exps);
            wasm_instance_delete(inst);
        }
        wasm_func_delete(hostfn);       /* frees the host func (owns its functype copy) */
        wasm_functype_delete(addtype);
        wasm_module_delete(impmodule);
    }
    wasm_byte_vec_delete(&impbin);

    /*
     * Exported global + memory: read/write the module's state from C.
     *   (global (export "g") (mut i32) (i32.const 7))
     *   (memory (export "mem") 1)
     *   (func (export "store") (param i32 i32) (i32.store (local.get 0) (local.get 1)))
     */
    const unsigned char gmmod[] = {
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x00,       /* type (i32,i32)->() */
        0x03, 0x02, 0x01, 0x00,                               /* func 0 : type 0    */
        0x05, 0x03, 0x01, 0x00, 0x01,                         /* memory min 1       */
        0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x07, 0x0b,       /* global (mut i32)=7 */
        0x07, 0x13, 0x03, 0x01, 'g', 0x03, 0x00,              /* export g   global 0*/
        0x03, 'm', 'e', 'm', 0x02, 0x00,                      /* export mem memory 0*/
        0x05, 's', 't', 'o', 'r', 'e', 0x00, 0x00,            /* export store func 0*/
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x36, 0x02, 0x00, 0x0b, /* code */
    };
    wasm_byte_vec_t gmbin;
    wasm_byte_vec_new(&gmbin, sizeof(gmmod), (const wasm_byte_t *)gmmod);
    wasm_module_t *gmmodule = wasm_module_new(store, &gmbin);
    if (!gmmodule) {
        printf("FAIL: global/memory module decode\n");
        failures++;
    } else {
        wasm_extern_vec_t noimp2;
        wasm_extern_vec_new_empty(&noimp2);
        wasm_instance_t *gi = wasm_instance_new(store, gmmodule, &noimp2, NULL);
        wasm_extern_vec_t gex;
        wasm_instance_exports(gi, &gex);
        /* export order matches the export section: g, mem, store */
        wasm_global_t *g = wasm_extern_as_global(gex.data[0]);
        wasm_memory_t *mem = wasm_extern_as_memory(gex.data[1]);
        wasm_func_t *storefn = wasm_extern_as_func(gex.data[2]);

        wasm_val_t gv;
        wasm_global_get(g, &gv);
        printf("global g:        %d\n", gv.of.i32);
        if (gv.of.i32 != 7) failures++;
        wasm_val_t nv;
        nv.kind = WASM_I32; nv.of.i32 = 99;
        wasm_global_set(g, &nv);
        wasm_global_get(g, &gv);
        if (gv.of.i32 != 99) failures++;

        wasm_val_t sa[2];
        sa[0].kind = WASM_I32; sa[0].of.i32 = 0;
        sa[1].kind = WASM_I32; sa[1].of.i32 = 0x12345678;
        wasm_val_vec_t sargs, sres;
        wasm_val_vec_new(&sargs, 2, sa);
        wasm_val_vec_new_empty(&sres);
        wasm_func_call(storefn, &sargs, &sres);

        byte_t *data = wasm_memory_data(mem);
        int32_t mv = 0;
        memcpy(&mv, data, 4);
        printf("mem[0]:          0x%08x (size=%u)\n", (unsigned)mv, wasm_memory_size(mem));
        if ((unsigned)mv != 0x12345678u) failures++;

        bool grew = wasm_memory_grow(mem, 1);
        printf("mem grow +1:     %s (size=%u)\n", grew ? "ok" : "no", wasm_memory_size(mem));
        if (!grew || wasm_memory_size(mem) != 2) failures++;

        wasm_val_vec_delete(&sargs);
        wasm_val_vec_delete(&sres);
        wasm_extern_vec_delete(&gex);
        wasm_instance_delete(gi);
        wasm_module_delete(gmmodule);
    }
    wasm_byte_vec_delete(&gmbin);

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
