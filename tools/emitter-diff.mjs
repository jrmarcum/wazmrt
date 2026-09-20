#!/usr/bin/env -S deno run --allow-read --allow-write --allow-run
// tools/emitter-diff.mjs — Track B-a's mechanical emitter audit.
//
// Assembles the same WebAssembly TEXT with wazmrt and with a second,
// independent assembler, and compares the resulting BYTES. Every disagreement
// is either a fact one emitter dropped or a shorthand the two choose
// differently, and both are worth knowing.
//
// 🔑 **Why bytes and not behaviour.** Every other gate this project owns asks
// "does this module behave correctly?". This one asks "is this the same module
// another toolchain would have built?" — and the four defects it found in
// September 2026 were all behaviour-PRESERVING under wazmrt's own tests:
//
//   - a block type that is a non-null abstract ref was emitted as wazmrt's
//     INTERNAL enum tag, which our decoder read back happily and no other
//     runtime could load at all;
//   - the same branch dropped the `exact` former on concrete refs;
//   - `any.convert_extern` / `extern.convert_any` had their wire bytes swapped
//     in four places that all agreed with each other;
//   - a folded `if` emitted only the FIRST of its condition expressions,
//     inverting the condition — in a spec-test function whose `then` and `else`
//     are both empty, so nothing observable changed.
//
// ⚠️ **This is an OPTIONAL check and it reaches outside the repo**, like the
// Bake Off and the spec corpus. It needs a second assembler; nothing in
// `zig build` depends on it and the default build stays self-contained.
//
// USAGE
//   deno run -A tools/emitter-diff.mjs \
//       --suite <spec-testsuite-dir> \
//       --wazmrt <path-to-wazmrt.exe> \
//       --other  <path-to-second-runtime> \
//       [--out <scratch-dir>] [--list]
//
// The second runtime must accept `pin <file|dir>` and print
// `<64-hex>  <path>` lines, which is the contract `interop.md` §3.1 already
// fixes between the two projects.

const args = new Map();
for (let i = 0; i < Deno.args.length; i++) {
  const a = Deno.args[i];
  if (a.startsWith("--")) {
    const next = Deno.args[i + 1];
    if (next && !next.startsWith("--")) { args.set(a.slice(2), next); i++; }
    else args.set(a.slice(2), true);
  }
}
const suite = args.get("suite");
const wazmrt = args.get("wazmrt");
const other = args.get("other");
const outDir = args.get("out") ?? "./.emitter-diff";
if (!suite || !wazmrt || !other) {
  console.error("usage: deno run -A tools/emitter-diff.mjs --suite <dir> --wazmrt <exe> --other <exe> [--out <dir>] [--list]");
  Deno.exit(2);
}

// ---- 1. Extract every TOP-LEVEL `(module …)` into a standalone `.wat` -------
//
// Top-level only, on purpose: a module nested in `assert_malformed` /
// `assert_invalid` is SUPPOSED to be rejected, so a disagreement there is a
// validity question, not an emitter one. `(module binary …)` and
// `(module quote …)` are skipped — they are not text modules.
//
// The scanner is a real s-expression walk, not a regex: `.wast` files contain
// `;;` line comments, `(; … ;)` nesting block comments and string literals with
// escapes, and every one of those can hold an unbalanced paren.
function* topLevelModules(text) {
  let i = 0;
  const n = text.length;
  const skipTrivia = () => {
    if (text[i] === ";" && text[i + 1] === ";") {
      while (i < n && text[i] !== "\n") i++;
      return true;
    }
    if (text[i] === "(" && text[i + 1] === ";") {
      let d = 1;
      i += 2;
      while (i < n && d > 0) {
        if (text[i] === "(" && text[i + 1] === ";") { d++; i += 2; continue; }
        if (text[i] === ";" && text[i + 1] === ")") { d--; i += 2; continue; }
        i++;
      }
      return true;
    }
    return false;
  };
  while (i < n) {
    if (skipTrivia()) continue;
    if (text[i] !== "(") { i++; continue; }
    const start = i;
    let depth = 0;
    while (i < n) {
      if (skipTrivia()) continue;
      const ch = text[i];
      if (ch === '"') {
        i++;
        while (i < n && text[i] !== '"') { if (text[i] === "\\") i++; i++; }
        i++;
        continue;
      }
      if (ch === "(") depth++;
      else if (ch === ")") { depth--; if (depth === 0) { i++; break; } }
      i++;
    }
    const form = text.slice(start, i);
    if (/^\(\s*module\b/.test(form) && !/^\(\s*module\s+(\$[^\s()]+\s+)?(binary|quote)\b/.test(form)) {
      yield form;
    }
  }
}

await Deno.mkdir(outDir, { recursive: true });
let modules = 0;
for await (const ent of Deno.readDir(suite)) {
  if (!ent.isFile || !ent.name.endsWith(".wast")) continue;
  const text = await Deno.readTextFile(`${suite}/${ent.name}`);
  let k = 0;
  for (const form of topLevelModules(text)) {
    const base = ent.name.replace(/\.wast$/, "");
    await Deno.writeTextFile(`${outDir}/${base}__${String(k++).padStart(3, "0")}.wat`, form + "\n");
    modules++;
  }
}

// ---- 2. Pin the lot with each assembler -------------------------------------
async function pin(exe) {
  const o = await new Deno.Command(exe, { args: ["pin", outDir], stdout: "piped", stderr: "piped" }).output();
  return new TextDecoder().decode(o.stdout) + new TextDecoder().decode(o.stderr);
}
// ⚠️ Parse ONLY `<64 hex>  <path>` lines. Both tools print skip warnings, and
// wazmrt prints them on stdout interleaved with the pin lines (`known-issues`).
function parse(text) {
  const m = new Map();
  for (const line of text.split(/\r?\n/)) {
    const hit = /^([0-9a-f]{64})\s\s(.+)$/.exec(line);
    if (hit) m.set(hit[2].replace(/\\/g, "/").toLowerCase(), hit[1]);
  }
  return m;
}
const A = parse(await pin(wazmrt));
const B = parse(await pin(other));

const differ = [];
let agree = 0;
for (const [p, d] of A) {
  if (!B.has(p)) continue;
  if (B.get(p) === d) agree++;
  else differ.push(p);
}
const onlyA = [...A.keys()].filter((p) => !B.has(p));
const onlyB = [...B.keys()].filter((p) => !A.has(p));

console.log(`${modules} modules extracted from ${suite}`);
console.log(`agree ${agree} · differ ${differ.length} · only-wazmrt ${onlyA.length} · only-other ${onlyB.length}`);
if (onlyA.length) console.log(`  ⚠️ assembled ONLY by wazmrt (the other refused them): ${onlyA.length}`);
if (onlyB.length) console.log(`  ⚠️ assembled ONLY by the other (wazmrt refused them): ${onlyB.length}`);
if (args.get("list")) for (const p of differ) console.log("  " + p);

// A disagreement is a finding to classify, not automatically a defect — see the
// header. Exit 1 so a scheduled run is noticed; the residual set is recorded in
// `cmem/testing.md` and should be compared against, not assumed to be zero.
Deno.exit(differ.length === 0 && onlyA.length === 0 && onlyB.length === 0 ? 0 : 1);
