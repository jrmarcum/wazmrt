// bakeoff.mjs — Track 3: measure wazmrt against the runtimes it means to replace,
// on real modules, with the comparison configured fairly.
//
// ⚠️ WHAT THIS MEASURES, EXACTLY: end-to-end PROCESS wall-clock for
// `spawn → read → decode → validate → instantiate → run → exit`. That is what
// one invocation costs in the dev loop this project targets (Decision 2: the
// consumer regime is un-precompiled `.wasm`, many short runs). It is NOT an
// in-process decode/instantiate timing, and it is NOT steady-state throughput —
// a JIT wins hot loops and this harness would hide that. Say which one a number
// is before quoting it.
//
// ⚠️ BINDING FAIRNESS RULE (cmem/roadmap.md): wasmtime is measured in its
// FAST-START configurations as well as its default. Beating a compiler in its
// slowest-starting mode proves nothing.
//
// ⚠️ REP-LEVEL INTERLEAVING, and it is not decoration. Measuring runtime A's
// reps then runtime B's compares two different moments; on a loaded machine that
// drifts enough to invent a result. This project measured a 40% "regression"
// that way and it was entirely drift — three repeats with no code change climbed
// 9.6 → 12.9 ms. Every runtime is sampled once per rep, so competing samples sit
// milliseconds apart and shared drift cancels.
//
// TWO MODES:
//   invoke — call an exported function, expected value from a `.test.json`.
//   start  — run a WASI `_start` program. No oracle is privileged: every runtime
//            must produce the SAME stdout, and a disagreement is reported rather
//            than adjudicated. This mode is also where `wazero` can compete at
//            all (its CLI runs `_start` only), and where LARGE modules live, so
//            it is the one that separates compile time from fixed startup.
//
// Usage: deno run --allow-read --allow-run --allow-env tools/bakeoff.mjs <dir> [reps] [mode]

const [corpusDir, repsArg, modeArg] = Deno.args;
if (!corpusDir) {
  console.error("usage: bakeoff.mjs <corpus-dir> [reps] [invoke|start]");
  Deno.exit(2);
}
const REPS = Number(repsArg ?? 7);
const MODE = modeArg ?? "invoke";

const here = (p) => new URL(p, import.meta.url).pathname.replace(/^\//, "");
const WAZMRT = here("../zig-out/bin/wazmrt.exe");
const WASMRT = here("../../wasmrt/target/release/wasmrt.exe");

const RUNTIMES = [
  { id: "wazmrt", note: "interpreter (Zig)", cmd: WAZMRT,
    invoke: (m, f, a) => [m, f, ...a], start: (m) => [m] },
  // The sibling project — the other candidate for the same slot.
  { id: "wasmrt", note: "interpreter (Rust)", cmd: WASMRT,
    invoke: (m, f, a) => ["run", m, f, ...a], start: (m) => ["wasi", m] },
  // The FAIR comparators for a startup metric — wasmtime told to start fast.
  { id: "wasmtime:winch", note: "baseline compiler", cmd: "wasmtime",
    invoke: (m, f, a) => ["-C", "compiler=winch", "--invoke", f, m, ...a],
    start: (m) => ["run", "-C", "compiler=winch", m] },
  { id: "wasmtime:O0", note: "cranelift opt-level=0", cmd: "wasmtime",
    invoke: (m, f, a) => ["-O", "opt-level=0", "--invoke", f, m, ...a],
    start: (m) => ["run", "-O", "opt-level=0", m] },
  // The DEFAULT, kept only so the gap between the two is visible. Quoting this
  // one alone would be the unfair comparison the fairness rule forbids.
  { id: "wasmtime:default", note: "cranelift opt-level=2 — SLOWEST START", cmd: "wasmtime",
    invoke: (m, f, a) => ["--invoke", f, m, ...a], start: (m) => ["run", m] },
  { id: "wasmer", note: "default (cranelift)", cmd: "wasmer",
    // ⚠️ The `--` matters: without it a negative argument parses as a flag and
    // the run fails, which the harness then reports as a WRONG ANSWER. A
    // benchmark that mis-invokes a competitor reports that competitor as broken.
    invoke: (m, f, a) => ["run", "--invoke", f, m, "--", ...a], start: (m) => ["run", m] },
  // wazero's CLI runs `_start` only — it cannot invoke a named export, so it can
  // appear in `start` mode and not in `invoke`. Recorded so its partial absence
  // reads as a fact about the tool rather than an omission.
  { id: "wazero", note: "compiler (Go)", cmd: "wazero", invoke: null, start: (m) => ["run", m] },
];

async function have(rt) {
  if (!rt[MODE]) return false;
  try {
    const p = new Deno.Command(rt.cmd, { args: ["--version"], stdout: "null", stderr: "null" }).spawn();
    await p.status;
    return true; // some CLIs exit non-zero on --version; being spawnable is the test
  } catch { return false; }
}

const decode = (b) => new TextDecoder().decode(b);

async function timeRun(rt, c) {
  const argv = MODE === "invoke" ? rt.invoke(c.wasm, c.fn, c.args.map(String)) : rt.start(c.wasm);
  const t0 = performance.now();
  const p = new Deno.Command(rt.cmd, { args: argv, stdout: "piped", stderr: "piped" }).spawn();
  const o = await p.output();
  const ms = performance.now() - t0;
  const text = decode(o.stdout);
  const all = text + decode(o.stderr);
  const ok = MODE === "invoke"
    ? o.success && new RegExp(`(^|\\D)${c.expected}(\\D|$)`).test(all)
    : o.success;
  return { ms, ok, out: text.trim(), last: all.trim().split("\n").slice(-1)[0] };
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[s.length >> 1]; };

// ---- the corpus -----------------------------------------------------------
const cases = [];
if (MODE === "invoke") {
  for await (const e of Deno.readDir(corpusDir)) {
    if (!e.name.endsWith(".test.json")) continue;
    const base = e.name.slice(0, -".test.json".length);
    const wasm = `${corpusDir}/${base}.wasm`;
    try { await Deno.stat(wasm); } catch { continue; }
    const spec = JSON.parse(await Deno.readTextFile(`${corpusDir}/${e.name}`));
    for (const [fn, invs] of Object.entries(spec)) {
      const inv = invs[invs.length - 1];
      if (typeof inv.expected !== "number") continue;
      cases.push({ base, wasm, fn, args: inv.args ?? [], expected: inv.expected });
    }
  }
} else {
  for await (const e of Deno.readDir(corpusDir)) {
    if (!e.name.endsWith(".wasm")) continue;
    const wasm = `${corpusDir}/${e.name}`;
    const { size } = await Deno.stat(wasm);
    cases.push({ base: e.name, wasm, size });
  }
  cases.sort((a, b) => a.size - b.size);
}
if (!cases.length) { console.error(`bakeoff: no runnable cases in ${corpusDir}`); Deno.exit(1); }

const field = [];
for (const rt of RUNTIMES) {
  if (await have(rt)) field.push(rt);
  else console.log(`  (skipping ${rt.id} — not runnable in '${MODE}' mode here)`);
}

console.log(`\n  Bake-off [${MODE}] — ${cases.length} case(s) x ${REPS} reps, END-TO-END PROCESS wall-clock (ms)`);
console.log(`  corpus: ${corpusDir}`);
console.log(`  runtimes sampled ONCE PER REP, interleaved, so drift cancels\n`);

const results = new Map(field.map((r) => [r.id, []]));
const bad = [];
const disagree = [];
for (const c of cases) {
  const per = new Map(field.map((r) => [r.id, []]));
  const outs = new Map();
  for (let rep = 0; rep < REPS; rep++) {
    for (const rt of field) {                       // <-- interleaved here
      const r = await timeRun(rt, c);
      if (!r.ok) { if (!bad.some((b) => b.rt === rt.id && b.base === c.base)) bad.push({ rt: rt.id, base: c.base, why: r.last }); continue; }
      per.get(rt.id).push(r.ms);
      if (MODE === "start" && !outs.has(rt.id)) outs.set(rt.id, r.out);
    }
  }
  // Differential check: in `start` mode nobody is the oracle, so they must agree.
  if (MODE === "start" && outs.size > 1) {
    const vals = [...new Set(outs.values())];
    if (vals.length > 1) disagree.push({ base: c.base, outs: [...outs.entries()] });
  }
  for (const rt of field) {
    const s = per.get(rt.id);
    if (s.length) results.get(rt.id).push({ c, med: median(s) });
  }
}

// ---- report ---------------------------------------------------------------
const pad = (s, n) => String(s).padEnd(n);
const base = results.get("wazmrt");
const baseMed = base?.length ? median(base.map((r) => r.med)) : NaN;
console.log(`  ${pad("runtime", 20)} ${pad("note", 32)} ${"median".padStart(9)}  cases`);
for (const rt of field) {
  const rs = results.get(rt.id);
  if (!rs.length) { console.log(`  ${pad(rt.id, 20)} ${pad(rt.note, 32)} ${"—".padStart(9)}  (all disqualified)`); continue; }
  const m = median(rs.map((r) => r.med));
  const rel = rt.id === "wazmrt" ? "" : `   ${(m / baseMed).toFixed(2)}x wazmrt`;
  console.log(`  ${pad(rt.id, 20)} ${pad(rt.note, 32)} ${m.toFixed(2).padStart(9)}  ${rs.length}${rel}`);
}

if (MODE === "start" && cases.length > 1) {
  console.log(`\n  per-module median (ms), smallest first — where compile time separates from fixed startup:`);
  const hdr = field.map((r) => pad(r.id.replace("wasmtime:", "wt:"), 12)).join(" ");
  console.log(`  ${pad("module", 30)} ${pad("bytes", 9)} ${hdr}`);
  for (const c of cases) {
    const row = field.map((rt) => {
      const e = results.get(rt.id).find((r) => r.c.base === c.base);
      return pad(e ? e.med.toFixed(1) : "—", 12);
    }).join(" ");
    console.log(`  ${pad(c.base.slice(0, 29), 30)} ${pad(c.size, 9)} ${row}`);
  }
}

if (bad.length) {
  console.log(`\n  ⚠️  disqualified (wrong or failed result — not scored):`);
  for (const b of bad) console.log(`     ${b.rt}: ${b.base} — ${b.why}`);
}
if (disagree.length) {
  console.log(`\n  ⚠️  RUNTIMES DISAGREED on output — no oracle is privileged, so this is reported, not adjudicated:`);
  for (const d of disagree) for (const [id, o] of d.outs) console.log(`     ${d.base} ${pad(id, 18)} ${JSON.stringify(o.slice(0, 60))}`);
}

console.log(`
  One invocation, end to end — the dev-loop regime. Not in-process decode time,
  not steady-state throughput. wasmtime's fast-start rows are the fair
  comparators; its default row shows the spread between them.
`);
