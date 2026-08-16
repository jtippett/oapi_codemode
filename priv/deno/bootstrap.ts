// Line-delimited JSON protocol over stdin/stdout.
// In:  {"type":"start","code":"...","globals":{...}}
//      {"type":"callback_result","id":"...","ok":...} | {"type":"callback_result","id":"...","error":"..."}
// Out: {"type":"callback","id":"...","name":"request","args":[...]}
//      {"type":"done","ok":{"value":...,"logs":[...]}} | {"type":"done","error":"..."}
//
// No imports from jsr/npm/https: this process runs with no --allow-net, and
// even if it had network, a runtime-fetched dependency here would be a
// supply-chain door into the sandbox boundary. The line splitter below is
// hand-rolled instead of `jsr:@std/streams/text-line-stream` for that reason.

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };

const pending = new Map<string, Pending>();
const logs: string[] = [];
let nextId = 0;

const encoder = new TextEncoder();

// Captured before user code runs, so a malicious script that later nulls out
// or reassigns Deno.stdout.write/writeSync (see below) cannot stop us from
// speaking the protocol — and, crucially, cannot use the *original* writer
// to inject fake protocol lines either, since we hold the only reference.
// Synchronous on purpose: `send` is called right before `Deno.exit(0)` in
// the done/error paths, and an unawaited async write could be dropped by
// the exit before it flushes.
const realStdoutWriteSync = Deno.stdout.writeSync.bind(Deno.stdout);

function send(msg: unknown) {
  realStdoutWriteSync(encoder.encode(JSON.stringify(msg) + "\n"));
}

function rpc(name: string, args: unknown[]): Promise<unknown> {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ type: "callback", id, name, args });
  });
}

// Console capture: logs go back to Elixir, never to stdout directly.
console.log = (...args: unknown[]) => {
  logs.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
};
console.error = console.log;
console.warn = console.log;

function installGlobals(globals: Record<string, unknown>, apiNames: string[]) {
  for (const [k, v] of Object.entries(globals)) {
    (globalThis as Record<string, unknown>)[k] = v;
  }
  const apis: Record<string, unknown> = {};
  for (const name of apiNames) {
    apis[name] = { request: (opts: unknown) => rpc("request", [name, opts]) };
  }
  (globalThis as Record<string, unknown>)["apis"] = apis;
}

// Protocol-injection hardening: once user code starts running, remove its
// ability to write to stdout directly. console.log is already patched above
// so ordinary logging is safe; this closes the remaining hole where
// sandboxed code calls Deno.stdout.write/writeSync itself to forge a
// "done"/"callback" line. Real replies still go out via realStdoutWrite,
// which was captured before this point.
function lockStdout() {
  const blocked = () => {
    throw new Error("stdout is not available to sandboxed code");
  };

  try {
    Object.defineProperty(Deno.stdout, "write", { value: blocked, configurable: true });
    Object.defineProperty(Deno.stdout, "writeSync", { value: blocked, configurable: true });
  } catch {
    // If Deno.stdout's properties are not reconfigurable in this Deno
    // version, we fall back to leaving it writable. Residual risk: sandboxed
    // code could inject a forged protocol line (e.g. a fake "done"). Low
    // severity — the sandbox already has no permissions (no net/fs/env), so
    // the worst case is a confused result for this one run, not an escape.
  }
}

async function runCode(code: string): Promise<unknown> {
  const moduleSource = `export default ${code}`;
  const url = "data:text/typescript;base64," +
    btoa(String.fromCharCode(...new TextEncoder().encode(moduleSource)));
  const mod = await import(url);
  if (typeof mod.default !== "function") {
    throw new Error("code must be an async arrow function");
  }
  return await mod.default();
}

function cleanError(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e);
  // First line only; no data-URL stack frames or paths reach the agent.
  return msg.split("\n")[0].slice(0, 500);
}

// Manual line splitter, vendored instead of jsr:@std/streams/text-line-stream
// to keep this process's dependency graph at zero network fetches. Buffers
// partial lines across chunk boundaries so arbitrarily large single lines
// (a multi-MB "start" message with a big globals payload) are handled
// correctly regardless of how the OS pipes chunk the bytes.
async function* readLines(readable: ReadableStream<string>): AsyncGenerator<string> {
  const reader = readable.getReader();
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += value;
      let newlineIndex: number;
      while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
        yield buffer.slice(0, newlineIndex);
        buffer = buffer.slice(newlineIndex + 1);
      }
    }
    if (buffer.length > 0) yield buffer;
  } finally {
    reader.releaseLock();
  }
}

const lines = readLines(Deno.stdin.readable.pipeThrough(new TextDecoderStream()));

let started = false;
for await (const line of lines) {
  if (line.trim() === "") continue;
  const msg = JSON.parse(line);

  if (msg.type === "start" && !started) {
    started = true;
    installGlobals(msg.globals ?? {}, msg.apiNames ?? []);
    lockStdout();
    // Run without awaiting the message loop: callbacks resolve as
    // callback_result lines arrive, so Promise.all works.
    runCode(msg.code)
      .then((value) => {
        send({ type: "done", ok: { value: value === undefined ? null : value, logs } });
        Deno.exit(0);
      })
      .catch((e) => {
        send({ type: "done", error: cleanError(e), logs });
        Deno.exit(0);
      });
  } else if (msg.type === "callback_result") {
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      if ("error" in msg) p.reject(new Error(msg.error));
      else p.resolve(msg.ok);
    }
  }
}
