// phases.mjs — Track 3's last item: what the ENGINE costs, with process spawn
// taken out of the picture.
//
// WHY THIS EXISTS. `bakeoff.mjs` times whole processes, and on this platform
// ~90% of that is spawn: `wazmrt --version`, which touches no wasm at all, costs
// ~30 ms of a ~33 ms run. So the end-to-end number cannot tell you whether a
// runtime is ahead because its engine is fast or because its binary is small.
// Both matter; they are different claims. This separates them.
//
// HOW EACH SIDE IS MEASURED, and the two are NOT the same shape:
//
//   wazmrt   — IN-PROCESS, from `zig build bench -- hash`, which times
//              `decode`, `decode+validate` and `decode+instantiate` directly.
//              No subtraction, no spawn.
//   wasmtime — `wasmtime compile`, with that runtime's OWN measured spawn floor
//              (`wasmtime --version`) subtracted. Floor and work are sampled
//              ALTERNATELY so drift hits both equally rather than biasing the
//              subtraction.
//
// ⚠️ THE COMPARABLE QUANTITY IS "BYTES → READY TO EXECUTE", NOT A PHASE-BY-PHASE
// ROW. wasmtime's pipeline produces NATIVE CODE; wazmrt's produces a validated
// IR to interpret. There is no honest way to line `validate` up against
// `compile`. What is comparable is how long each takes to get from a byte slice
// to something it can run — and the answer only means anything next to the
// trade: wasmtime pays far more up front and wins in a hot loop. Quoting this
// table without that sentence would be the same error as quoting a hot-loop
// benchmark without saying it is one.
//
// ⚠️ wasmtime's figure also includes WRITING the `.cwasm` to disk, which nothing
// on the wazmrt side does. It is an over-estimate of its compute by that much.
//
// ⚠️ FAIRNESS RULE: wasmtime is measured in its fast-start configurations as
// well as its default, and `winch` is the one to quote against.
//
// ⚠️ Two things cost a debugging round here, both worth keeping in mind:
// `std.debug.print` writes to STDERR, so a driver reading only stdout sees
// nothing and reports "no data" instead of "wrong stream"; and nesting
// `zig build bench` inside a build step contends for the build lock. The bench
// BINARY is passed in by `build.zig` (`addArtifactArg`) for both reasons.
//
// Usage: deno run --allow-read --allow-run --allow-write tools/phases.mjs <bench-exe> <tmp.cwasm> <module.wasm>...

const [benchExe, scratch, ...modules] = Deno.args;
if (!modules.length) {
  console.error("usage: phases.mjs <bench-exe> <scratch.cwasm> <module.wasm>...");
  Deno.exit(2);
}
const REPS = 13;
const med = (x) => { const s = [...x].sort((a, b) => a - b); return s[s.length >> 1]; };

async function run(cmd, args) {
  const d = new TextDecoder();
  const t = performance.now();
  const p = new Deno.Command(cmd, { args, stdout: "piped", stderr: "piped" }).spawn();
  const o = await p.output();
  // BOTH streams: Zig's `std.debug.print` goes to stderr.
  return { ms: performance.now() - t, ok: o.success, out: d.decode(o.stdout) + d.decode(o.stderr) };
}

// ---- wazmrt: in-process, straight from the bench binary --------------------
const wazmrt = new Map();
{
  const r = await run(benchExe, ["hash", ...modules]);
  for (const line of r.out.split("\n")) {
    if (!line.startsWith("PHASES\t")) continue;
    const [, path, bytes, dec, dv, di] = line.trim().split("\t");
    wazmrt.set(path.split(/[\\/]/).pop(), {
      bytes: +bytes, decode: +dec, validate: +dv - +dec, ready: +dv, instantiate: +di,
    });
  }
  if (!wazmrt.size) console.error("  (no PHASES lines from the bench binary — check both streams are read)");
}

// ---- wasmtime: compile, minus its own floor, configs interleaved -----------
const CFG = [["default", []], ["O0", ["-O", "opt-level=0"]], ["winch", ["-C", "compiler=winch"]]];
const wt = new Map();
for (const m of modules) {
  const name = m.split(/[\\/]/).pop();
  const floor = [], work = new Map(CFG.map(([n]) => [n, []]));
  for (let i = 0; i < REPS; i++) {
    floor.push((await run("wasmtime", ["--version"])).ms);
    for (const [n, flags] of CFG) {
      const r = await run("wasmtime", ["compile", ...flags, m, "-o", scratch]);
      if (r.ok) work.get(n).push(r.ms);
    }
  }
  const f = med(floor);
  wt.set(name, { floor: f, ...Object.fromEntries(CFG.map(([n]) => [n, work.get(n).length ? med(work.get(n)) - f : NaN])) });
}

// ---- report ---------------------------------------------------------------
const pad = (s, n) => String(s).padEnd(n);
const ms = (x) => (Number.isFinite(x) ? x.toFixed(2) : "—").padStart(8);
console.log(`\n  Engine pipeline — bytes to ready-to-execute, spawn excluded (ms)\n`);
console.log(`  ${pad("module", 28)} ${"bytes".padStart(9)} ${"wazmrt".padStart(8)} ${"wt:winch".padStart(8)} ${"wt:O0".padStart(8)} ${"wt:dflt".padStart(8)}   ratio`);
for (const m of modules) {
  const name = m.split(/[\\/]/).pop();
  const a = wazmrt.get(name), b = wt.get(name);
  if (!a || !b) { console.log(`  ${pad(name, 28)} (missing a side)`); continue; }
  const ours = a.ready / 1000; // us -> ms
  const best = Math.min(...[b.winch, b.O0, b.default].filter(Number.isFinite));
  console.log(`  ${pad(name, 28)} ${String(a.bytes).padStart(9)} ${ms(ours)} ${ms(b.winch)} ${ms(b.O0)} ${ms(b.default)}   ${(best / ours).toFixed(0)}x`);
}
console.log(`\n  wazmrt's own split (us, in-process):`);
console.log(`  ${pad("module", 28)} ${"decode".padStart(9)} ${"validate".padStart(9)} ${"+instantiate".padStart(13)}`);
for (const m of modules) {
  const a = wazmrt.get(m.split(/[\\/]/).pop());
  if (a) console.log(`  ${pad(m.split(/[\\/]/).pop(), 28)} ${a.decode.toFixed(2).padStart(9)} ${a.validate.toFixed(2).padStart(9)} ${a.instantiate.toFixed(2).padStart(13)}`);
}
console.log(`
  ⚠️  The two sides are different SHAPES: wasmtime emits native code, wazmrt a
      validated IR to interpret. The ratio says how fast each gets from bytes to
      something runnable — and it only means anything beside the trade it buys:
      wasmtime pays this once and wins in a hot loop. wasmtime's figure also
      includes writing the .cwasm, which nothing here on the wazmrt side does.
`);
