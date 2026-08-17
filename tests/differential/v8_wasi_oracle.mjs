import { WASI } from "node:wasi";
import { readFile } from "node:fs/promises";
const wasi = new WASI({ version: "preview1", args: ["m"], env: {} });
const bytes = await readFile(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, wasi.getImportObject());
wasi.start(instance);
