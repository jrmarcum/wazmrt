// bakeoff.mjs — Track 3: measure wazmrt against the runtimes it means to replace,
// on real modules, with the comparison configured fairly.
//
// ⚠️ WHAT THIS MEASURES, EXACTLY: end-to-end PROCESS wall-clock for
// `spawn → read → decode → validate → instantiate → call → print → exit`.
// That is what one invocation costs in the dev loop this project targets
// (Decision 2: the consumer regime is un-precompiled `.wasm`, many short runs).
// It is NOT an in-process decode/instantiate timing, and it is NOT steady-state
// throughput — a JIT wins hot loops and this harness would hide that. Say which
// one a number is before quoting it; the roadmap has a standing rule against
// claims that die on first contact with someone who checks.
//
// ⚠️ BINDING FAIRNESS RULE (cmem/roadmap.md): wasmtime is measured in its
// FAST-START configurations as well as its default. Beating a runtime in its
// slowest-starting configuration proves nothing, and publishing that number is
// the same error as the falsified wasm-c-api payoff.
//
// Correctness is checked on every single run. A benchmark that does not verify
// its output is measuring the wrong thing — and a runtime that answers wrongly
// is disqualified for that case, loudly, rather than scoring a fast time.
//
// Usage: deno run --allow-read --allow-run --allow-env tools/bakeoff.mjs <corpus-dir> [reps]

const [corpusDir, repsArg] = Deno.args;
if (!corpusDir) {
  console.error("usage: bakeoff.mjs <corpus-dir> [reps]");
  console.error("  <corpus-dir> holds *.wasm beside *.test.json (wasmtk's tests/module/wasm_mod)");
  Deno.exit(2);
}
const REPS = Number(repsArg ?? 7);

// ---- the field ------------------------------------------------------------
// `args(mod, fn, a)` builds the argv. `null` where a runtime cannot express the
// call at all — recorded as absent rather than quietly dropped.
const WAZMRT = new URL("../zig-out/bin/wazmrt.exe", import.meta.url).pathname.replace(/^\//, "");
const RUNTIMES = [
  { id: "wazmrt", note: "interpreter", cmd: WAZMRT, args: (m, f, a) => [m, f, ...a] },
  // The FAIR comparators for a startup metric — wasmtime told to start fast.
  { id: "wasmtime:winch", note: "baseline compiler", cmd: "wasmtime", args: (m, f, a) => ["-C", "compiler=winch", "--invoke", f, m, ...a] },
  { id: "wasmtime:O0", note: "cranelift opt-level=0", cmd: "wasmtime", args: (m, f, a) => ["-O", "opt-level=0", "--invoke", f, m, ...a] },
  // The DEFAULT, kept only so the gap between the two is visible. Quoting this
  // one alone would be the unfair comparison the fairness rule forbids.
  { id: "wasmtime:default", note: "cranelift opt-level=2 — SLOWEST START", cmd: "wasmtime", args: (m, f, a) => ["--invoke", f, m, ...a] },
  // ⚠️ The `--` matters and its absence looked like a wasmer DEFECT. Without it
  // a negative argument (`add 100 -1`) is parsed as a flag and the run fails,
  // so the harness disqualified wasmer on a case it answers correctly. **A
  // benchmark that mis-invokes a competitor reports that competitor as broken**
  // — check a disqualification against a hand-run before believing it.
  { id: "wasmer", note: "default (cranelift)", cmd: "wasmer", args: (m, f, a) => ["run", "--invoke", f, m, "--", ...a] },
  // wazero is in wasmtk's cross-runtime list but its CLI runs `_start` only —
  // it cannot invoke a named export, so it cannot appear in this table at all.
  // Recorded here so its absence reads as a fact about the tool, not an omission.
];

async function have(cmd) {
  try {
    const p = new Deno.Command(cmd, { args: ["--version"], stdout: "null", stderr: "null" }).spawn();
    return (await p.status).success;
  } catch { return false; }
}

async function timeRun(rt, mod, fn, args, expected) {
  const argv = rt.args(mod, fn, args.map(String));
  const t0 = performance.now();
  const p = new Deno.Command(rt.cmd, { args: argv, stdout: "piped", stderr: "piped" }).spawn();
  const out = await p.output();
  const ms = performance.now() - t0;
  const text = new TextDecoder().decode(out.stdout) + new TextDecoder().decode(out.stderr);
  // Every runtime prints the result differently; all we require is that the
  // expected value appears as a standalone token somewhere in the output.
  const ok = out.success && new RegExp(`(^|\\D)${expected}(\\D|$)`).test(text);
  return { ms, ok, text: text.trim().split("\n").slice(-1)[0] };
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };

// ---- the corpus -----------------------------------------------------------
const cases = [];
for await (const e of Deno.readDir(corpusDir)) {
  if (!e.name.endsWith(".test.json")) continue;
  const base = e.name.slice(0, -".test.json".length);
  const wasm = `${corpusDir}/${base}.wasm`;
  try { await Deno.stat(wasm); } catch { continue; }
  const spec = JSON.parse(await Deno.readTextFile(`${corpusDir}/${e.name}`));
  for (const [fn, invocations] of Object.entries(spec)) {
    // One representative invocation per export — the heaviest, so the measured
    // work is dominated by the module rather than by process spawn where possible.
    const inv = invocations[invocations.length - 1];
    if (typeof inv.expected !== "number") continue;
    cases.push({ base, wasm, fn, args: inv.args ?? [], expected: inv.expected });
  }
}
cases.sort((a, b) => a.base.localeCompare(b.base));
if (cases.length === 0) { console.error(`bakeoff: no runnable cases in ${corpusDir}`); Deno.exit(1); }

// ---- run ------------------------------------------------------------------
const field = [];
for (const rt of RUNTIMES) {
  if (await have(rt.cmd)) field.push(rt);
  else console.log(`  (skipping ${rt.id} — '${rt.cmd}' not runnable here)`);
}
if (!field.some((r) => r.id === "wazmrt")) {
  console.error("bakeoff: wazmrt itself is missing — run `zig build -Doptimize=ReleaseFast` first.");
  Deno.exit(1);
}

console.log(`\n  Bake-off — ${cases.length} invocation(s) x ${REPS} reps, END-TO-END PROCESS wall-clock (ms)`);
console.log(`  corpus: ${corpusDir}\n`);

const results = new Map(field.map((r) => [r.id, []]));
const wrong = [];
for (const c of cases) {
  for (const rt of field) {
    const samples = [];
    let bad = null;
    for (let i = 0; i < REPS; i++) {
      const r = await timeRun(rt, c.wasm, c.fn, c.args, c.expected);
      if (!r.ok) { bad = r; break; }
      samples.push(r.ms);
    }
    if (bad) { wrong.push({ rt: rt.id, c, got: bad.text }); continue; }
    results.get(rt.id).push({ c, med: median(samples), min: Math.min(...samples) });
  }
}

// ---- report ---------------------------------------------------------------
const pad = (s, n) => String(s).padEnd(n);
const num = (x, n = 8) => x.toFixed(2).padStart(n);
console.log(`  ${pad("runtime", 20)} ${pad("note", 30)} ${"median".padStart(8)} ${"min".padStart(8)}  cases`);
const base = results.get("wazmrt");
const baseMed = base.length ? median(base.map((r) => r.med)) : NaN;
for (const rt of field) {
  const rs = results.get(rt.id);
  if (!rs.length) { console.log(`  ${pad(rt.id, 20)} ${pad(rt.note, 30)} ${"—".padStart(8)} ${"—".padStart(8)}  (all disqualified)`); continue; }
  const m = median(rs.map((r) => r.med));
  const rel = rt.id === "wazmrt" ? "" : `   ${(m / baseMed).toFixed(2)}x wazmrt`;
  console.log(`  ${pad(rt.id, 20)} ${pad(rt.note, 30)} ${num(m)} ${num(Math.min(...rs.map((r) => r.min)))}  ${rs.length}${rel}`);
}

if (wrong.length) {
  console.log(`\n  ⚠️  ${wrong.length} case(s) DISQUALIFIED for a wrong or failed result — not scored:`);
  for (const w of wrong) console.log(`     ${w.rt}: ${w.c.base} ${w.c.fn}(${w.c.args}) expected ${w.c.expected}, got: ${w.got}`);
}

console.log(`
  Read this as: what ONE invocation costs end to end, which is the dev-loop
  regime this project targets. It is not in-process decode time and not
  steady-state throughput — a JIT wins hot loops, and this table cannot see that.
  wasmtime's fast-start rows are the fair comparators; its default row is shown
  only so the spread between them is visible.
`);
