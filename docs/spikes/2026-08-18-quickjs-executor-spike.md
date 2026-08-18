# Spike: native QuickJS as a memory-containable executor runtime

Empirical results (2026-08-18, macOS, ~4ms-startup stock binaries) toward an
`OapiCodemode.Executor.QuickJS` answering ele's blocking FEEDBACK.md entry:
V8/Deno has no hard memory cap (`--max-old-space-size` bypassed by ArrayBuffer
backing stores — 2GB RSS under a 64MB "cap").

## Verdicts

**Memory cap is real, ArrayBuffers included.** `qjs --memory-limit` (wired to
`JS_SetMemoryLimit`, which meters *all* allocation through `js_malloc`) stops
ele's exact repro — a loop of 50MB `ArrayBuffer`s under a 64MB limit — on the
first allocation, in-language and catchable. Peak RSS 54.6MB (Bellard) /
2.5MB (quickjs-ng, rejected before touching pages). Object-graph growth:
caught with ~9% overshoot (70MB peak at a 64MB cap), not runaway.

**The X-spec search workload fits easily.** Real 4,026,633-byte sandbox
payload (dereferenced `x_api.json`, 149 paths): `JSON.parse` 34–36ms,
representative filter search ≤1ms, ~42MB RSS. Minimum viable memory limit
bisected to 34–36MB (~9x the JSON payload for the object graph). Production
default: 128–256MB gives ample headroom while staying a real bound.

**Concurrent callbacks survive single-threaded stdio.** No hand-rolled
blocking pump needed: `os.setReadHandler` hooks the qjs CLI's own job loop,
giving event-driven stdio that interleaves with the microtask queue. Verified:
`Promise.all` over two `apis.*.request` calls wrote both callback lines before
either reply was read; out-of-order replies matched by id; results in original
array order.

## The fork landmine (do not get this wrong in a Dockerfile)

`brew install quickjs` = **Bellard's** QuickJS (2026-06-04), and it is NOT
sandboxable by flags: the module loader ignores `--std` entirely, so any
module can `import * as os from "os"` and reach `os.exec` (verified: ran a
real subprocess), `std.getenv`, `os.readdir` — unconditionally.

`brew install quickjs-ng` (v0.16.1, conflicts on the `qjs` name) genuinely
gates the loader: `import "os"`/`"std"` fail even *with* `--std` (the flag
only injects globals), and without `--std` neither module is reachable by any
route found. **Standardize on quickjs-ng.** The eventual executor should run
a boot-time canary (`import("os")` must reject) so the wrong-fork/wrong-binary
footgun fails loudly at startup, not silently at containment time.

## Gaps vs the Deno bootstrap (small, contained)

- `data:`-URL dynamic import (how `bootstrap.ts` turns the code string into a
  module) is unsupported in both forks. Options: eval the code string as an
  expression (`(${code})` — the contract is an async arrow already, no module
  machinery needed), temp-file `import()` (works, verified), or a custom C
  host calling `JS_Eval` with `JS_EVAL_TYPE_MODULE`. Prefer eval-expression:
  no temp files, no module loader in play at all.
- `TextEncoder`/`TextDecoder`/`ReadableStream` absent in both forks (~20-line
  shim or byte-level rewrite of the protocol layer). `btoa`/`atob` present in
  quickjs-ng only. No `setTimeout`/`queueMicrotask`/`fetch`/`crypto`.
- Bootstrap needs `--std` for its own stdio, so it must capture `std`/`os`
  into closures and delete the globals before evaluating model code (same
  pattern as the Deno bootstrap's `Deno.stdout` lock). Model code then has no
  import path (loader gated) and no globals.
- Hardening for the executor task: decide whether dynamic `import()` of local
  file paths is reachable from eval'd model code and close it if so (custom
  loader refusal or eval-only pipeline with no loader).

## Executor-relevant behavior notes

- Rope strings: `s += s` doubling allocates ~nothing until materialized
  (`.toUpperCase()`, encode, stdio write) — at which point the cap fires.
  Naive string bombs are inert by construction; forced flattening is capped.
- Under sustained small-allocation OOM pressure QuickJS may throw a bare
  `null` instead of an Error (can't afford to construct one). try/catch still
  fires; executor error paths must not assume `e.message` exists.
- `--stack-size` works (catchable stack overflow). No CPU/interrupt flag in
  either CLI; wall-clock deadline stays Elixir-side (already built).
- Startup ~4ms median (vs tens of ms for Deno); binary <1MB either fork.

Spike scripts lived in the session scratchpad (not committed); the
experiments are fully described above and in FEEDBACK.md's memory-limit
entries for re-derivation.
