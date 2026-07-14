;; A WASI preview-1 command module: write a line to stdout, then exit(0).
;; Run it with:  zig build && zig-out/bin/wazmrt examples/hello_wasi.wat
;; The CLI assembles the .wat, sees the exported `_start`, wires the
;; wasi_snapshot_preview1 host imports, and runs it.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)

  ;; The message, and space for the iovec + the returned byte count.
  (data (i32.const 16) "hello from wasi\n")

  (func (export "_start")
    ;; iovec at 0: { buf = 16, len = 16 }
    (i32.store (i32.const 0) (i32.const 16))
    (i32.store (i32.const 4) (i32.const 16))
    ;; fd_write(fd = 1 /stdout/, iovs = 0, iovs_len = 1, nwritten = 8)
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))
    (call $proc_exit (i32.const 0))))
