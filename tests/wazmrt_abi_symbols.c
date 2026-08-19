/*
 * wazmrt_abi_symbols.c — the link-time completeness gate for the ABI-2 surface.
 *
 * References EVERY function `wazmrt.h` declares, so a symbol we promise but never define breaks
 * THIS build instead of an embedder's link. That failure mode is not hypothetical: audit finding
 * #20 found the old C ABI declaring 180 functions it had never defined, invisible because our own
 * tests only ever called the ones we had implemented.
 *
 * GENERATED FROM THE HEADER. If you add a declaration, regenerate rather than hand-editing — the
 * point of the file is that it cannot disagree with what we publish.
 */
#include "wazmrt.h"
#include <stddef.h>

/* Taking each address forces the reference; the array keeps them all alive. */
const void *const wazmrt_abi_symbols[] = {
    (const void *)&wazmrt_abi_version,
    (const void *)&wazmrt_bytes_delete,
    (const void *)&wazmrt_caller_get_memory,
    (const void *)&wazmrt_caller_memory_size,
    (const void *)&wazmrt_caller_read,
    (const void *)&wazmrt_caller_write,
    (const void *)&wazmrt_config_all_features,
    (const void *)&wazmrt_config_delete,
    (const void *)&wazmrt_config_get_feature,
    (const void *)&wazmrt_config_new,
    (const void *)&wazmrt_config_set_feature,
    (const void *)&wazmrt_config_set_max_call_depth,
    (const void *)&wazmrt_config_set_max_iterations,
    (const void *)&wazmrt_config_set_max_exception_boxes,
    (const void *)&wazmrt_config_set_max_gc_objects,
    (const void *)&wazmrt_config_set_max_memory_bytes,
    (const void *)&wazmrt_config_set_max_table_elements,
    (const void *)&wazmrt_engine_delete,
    (const void *)&wazmrt_engine_new,
    (const void *)&wazmrt_engine_new_with_config,
    (const void *)&wazmrt_error_delete,
    (const void *)&wazmrt_error_message,
    (const void *)&wazmrt_func_call,
    (const void *)&wazmrt_func_is_valid,
    (const void *)&wazmrt_func_type,
    (const void *)&wazmrt_functype_delete,
    (const void *)&wazmrt_functype_new,
    (const void *)&wazmrt_functype_param,
    (const void *)&wazmrt_functype_param_count,
    (const void *)&wazmrt_functype_result,
    (const void *)&wazmrt_functype_result_count,
    (const void *)&wazmrt_global_get,
    (const void *)&wazmrt_global_is_valid,
    (const void *)&wazmrt_instance_get_func,
    (const void *)&wazmrt_instance_get_global,
    (const void *)&wazmrt_instance_get_memory,
    (const void *)&wazmrt_instance_initialize,
    (const void *)&wazmrt_instance_is_valid,
    (const void *)&wazmrt_linker_define_func,
    (const void *)&wazmrt_linker_define_global,
    (const void *)&wazmrt_linker_define_instance,
    (const void *)&wazmrt_linker_define_unknown_imports_as_traps,
    (const void *)&wazmrt_linker_define_wasi,
    (const void *)&wazmrt_linker_delete,
    (const void *)&wazmrt_linker_instantiate,
    (const void *)&wazmrt_linker_new,
    (const void *)&wazmrt_memory_data,
    (const void *)&wazmrt_memory_data_size,
    (const void *)&wazmrt_memory_is_valid,
    (const void *)&wazmrt_memory_read,
    (const void *)&wazmrt_memory_size_pages,
    (const void *)&wazmrt_memory_write,
    (const void *)&wazmrt_module_delete,
    (const void *)&wazmrt_module_export,
    (const void *)&wazmrt_module_export_count,
    (const void *)&wazmrt_module_import,
    (const void *)&wazmrt_module_import_count,
    (const void *)&wazmrt_module_new,
    (const void *)&wazmrt_module_new_wat,
    (const void *)&wazmrt_module_validate,
    (const void *)&wazmrt_store_delete,
    (const void *)&wazmrt_store_new,
    (const void *)&wazmrt_trap_delete,
    (const void *)&wazmrt_trap_frame,
    (const void *)&wazmrt_trap_frame_count,
    (const void *)&wazmrt_trap_message,
    (const void *)&wazmrt_trap_new,
    (const void *)&wazmrt_version_string,
    (const void *)&wazmrt_wasi_config_delete,
    (const void *)&wazmrt_wasi_config_inherit_stderr,
    (const void *)&wazmrt_wasi_config_inherit_stdin,
    (const void *)&wazmrt_wasi_config_inherit_stdout,
    (const void *)&wazmrt_wasi_config_new,
    (const void *)&wazmrt_wasi_config_preopen_dir,
    (const void *)&wazmrt_wasi_config_set_args,
    (const void *)&wazmrt_wasi_config_set_env,
    (const void *)&wazmrt_wasi_exit_code,
    (const void *)&wazmrt_wat_to_wasm,
};

const size_t wazmrt_abi_symbol_count = sizeof(wazmrt_abi_symbols) / sizeof(wazmrt_abi_symbols[0]);
