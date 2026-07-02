/*
 * wazmrt — extension header for the WebAssembly C API.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 * Copyright (c) 2026 Jon Marcum
 *
 * wazmrt's integration ABI IS the standard wasm-c-api (see <wasm.h>, vendored
 * at third_party/wasm-c-api/include/wasm.h). This header adds only the small
 * wazmrt-specific surface on top of it — the same pattern wasmtime uses with
 * its <wasmtime.h> alongside <wasm.h>. Include this; it pulls in <wasm.h>.
 *
 * Static linking on Windows: wazmrt ships a STATIC library, so compile
 * consumers with -DLIBWASM_STATIC (otherwise <wasm.h> declares the symbols
 * __declspec(dllimport)).
 */
#ifndef WAZMRT_H
#define WAZMRT_H

#include <stdint.h>
#include "wasm.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Stable wazmrt C-ABI version; verify it matches what you built against. */
uint32_t wazmrt_abi_version(void);

/* Static, NUL-terminated library version string; do not free. */
const char *wazmrt_version_string(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WAZMRT_H */
