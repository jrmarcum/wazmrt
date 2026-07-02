/*
 * wazmrt — C ABI for embedding the runtime from any language.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 * Copyright (c) 2026 Jon Marcum
 *
 * This header is the contract consumed by the universalWasmLoader-* loaders.
 * Handles are opaque; only these declarations and status codes are stable.
 */
#ifndef WAZMRT_H
#define WAZMRT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes: 0 is success, negatives are errors. */
typedef enum wazmrt_status {
    WAZMRT_OK = 0,
    WAZMRT_ERR_NULL = -1,
    WAZMRT_ERR_OOM = -2,
    WAZMRT_ERR_DECODE = -3
} wazmrt_status;

/* Opaque handle to a decoded module. */
typedef void wazmrt_module;

/* Stable ABI version; verify it matches what you built against. */
uint32_t wazmrt_abi_version(void);

/* Static, NUL-terminated version string; do not free. */
const char *wazmrt_version_string(void);

/*
 * Decode a WebAssembly binary. On WAZMRT_OK, *out_module owns a handle that
 * must be released with wazmrt_module_free.
 */
int wazmrt_module_decode(const uint8_t *bytes, size_t len,
                         wazmrt_module **out_module);

/* Number of top-level sections, or 0 for a NULL handle. */
size_t wazmrt_module_section_count(wazmrt_module *handle);

/* Release a handle from wazmrt_module_decode; NULL is a no-op. */
void wazmrt_module_free(wazmrt_module *handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WAZMRT_H */
