import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("..", import.meta.url));
const cancellation = new AbortController();

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.once(signal, () => cancellation.abort(new Error(`Interrupted by ${signal}`)));
}

assert.equal(typeof WebSocket, "function", "Use Node.js with built-in WebSocket support");
const { stdout: stage } = await execute(resolve(root, "scripts/bundle-t3-engine.sh"));
const stagePath = stage.trim().replace(/^T3 engine staged at /, "");
const pin = JSON.parse(await readFile(join(stagePath, "pin.json"), "utf8"));
assert.equal(pin.version, "0.1.12", "This probe verifies the v0.1.12 workflow contract");
const engine = join(stagePath, "t3");

const listener = net.createServer();
listener.listen(0, "127.0.0.1");
await once(listener, "listening");
const { port } = listener.address();
await promisify(listener.close.bind(listener))();
const origin = `http://127.0.0.1:${port}`;
const engineHome = await mkdtemp(join(tmpdir(), "botto-w18-live-"));
// Keep user and provider credentials out of the engine's process and login shell.
const env = {
  HOME: engineHome, TMPDIR: engineHome, PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
  SHELL: "/bin/bash", TZ: "UTC", NO_COLOR: "1",
};
const timeoutSignal = milliseconds => AbortSignal.any([
  cancellation.signal, AbortSignal.timeout(milliseconds),
]);

async function engineCall(arguments_, label) {
  try {
    return await execute(engine, arguments_, {
      cwd: engineHome, env, timeout: 15_000, signal: cancellation.signal,
    });
  } catch {
    // The CLI can include a live pairing link in its output.
    throw Error(`T3 ${label} failed`);
  }
}

async function start() {
  cancellation.signal.throwIfAborted();
  const supervisor = spawn("/usr/bin/python3", [resolve(root, "scripts/dev-process.py"), "run", "--grace", "5", "--",
    engine, "serve", "--host", "127.0.0.1", "--port", String(port), "--base-dir", engineHome],
  { cwd: engineHome, env, stdio: "ignore" });
  const exited = once(supervisor, "exit");
  const stop = async () => {
    if (supervisor.exitCode === null && supervisor.signalCode === null) supervisor.kill();
    await exited;
  };
  try {
    await until(async () => {
      if (supervisor.exitCode !== null) throw Error("T3 exited during startup");
      try {
        return (await fetch(`${origin}/.well-known/t3/environment`, { signal: timeoutSignal(1500) })).ok;
      } catch { return false; }
    }, "server startup", 30);
  } catch (error) {
    await stop();
    throw error;
  }
  return stop;
}

async function until(check, label, seconds) {
  const deadline = Date.now() + seconds * 1000;
  do {
    cancellation.signal.throwIfAborted();
    const value = await check();
    if (value) return value;
    await delay(1000, undefined, { signal: cancellation.signal });
  } while (Date.now() < deadline);
  throw Error(`Timed out waiting for ${label}`);
}

async function post(path, options = {}) {
  const response = await fetch(`${origin}${path}`, {
    method: "POST", signal: timeoutSignal(5000), redirect: "error", ...options,
  });
  assert.ok(response.ok, `${path} returned ${response.status}`);
  return response.json();
}

async function pair(label, scopes = []) {
  const args = scopes.flatMap(scope => ["--scope", scope]);
  const { stdout } = await engineCall(["pair", "--base-dir", engineHome, "--label", label, ...args], "pair");
  const raw = stdout.split("\n").find(line => line.startsWith("Pairing URL:"))?.slice("Pairing URL:".length).trim();
  if (!raw) throw Error("Pairing URL missing");
  const url = new URL(raw);
  assert.equal(url.origin, origin);
  const secret = new URLSearchParams(url.hash.slice(1)).get("token");
  if (!secret) throw Error("Pairing token missing");
  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: secret,
    subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    client_label: label, client_device_type: "mobile", client_os: "ios",
  });
  const { access_token: token, scope } = await post("/oauth/token", { body });
  if (!token) throw Error("No bearer token");
  return { token, scopes: scope.split(" ") };
}

async function rpc({ token }, method, payload = {}, { first = false, drop = false } = {}) {
  const { ticket } = await post("/api/auth/websocket-ticket/rpc", { headers: { Authorization: `Bearer ${token}` } });
  if (!ticket) throw Error("No WebSocket ticket");
  const address = new URL("/ws", origin);
  address.protocol = "ws:";
  address.searchParams.set("orchestrationProtocol", "2");
  address.searchParams.set("wsTicket", ticket);
  const socket = new WebSocket(address);
  try {
    return await new Promise((finish, reject) => {
      const signal = timeoutSignal(10_000);
      const interrupted = () => reject(Error(`RPC interrupted or timed out: ${method}`));
      signal.addEventListener("abort", interrupted, { once: true });
      const send = frame => socket.send(JSON.stringify(frame));
      const complete = (callback, value) => {
        signal.removeEventListener("abort", interrupted);
        callback(value);
      };
      socket.addEventListener("open", () => send({ _tag: "Request", id: "1", tag: method, payload, headers: [] }));
      socket.addEventListener("error", () => complete(reject, Error(`WebSocket failed: ${method}`)));
      socket.addEventListener("close", () => complete(reject, Error(`WebSocket closed: ${method}`)));
      socket.addEventListener("message", event => {
        try {
          const message = JSON.parse(event.data);
          if (message._tag === "Ping") send({ _tag: "Pong" });
          if (message._tag === "Defect") throw Error(`T3 defect: ${method}`);
          if (message._tag === "Chunk" && first && message.requestId === "1") {
            send({ _tag: "Ack", requestId: "1" });
            send({ _tag: "Interrupt", requestId: "1" });
            complete(finish, message.values[0]);
          }
          if (message._tag === "Exit" && message.requestId === "1") {
            if (message.exit._tag === "Success") {
              if (drop) complete(reject, Error("Response dropped by fixture"));
              else complete(finish, message.exit.value);
            } else throw Error(`${method}: ${JSON.stringify(message.exit.cause)}`);
          }
        } catch (error) { complete(reject, error); }
      });
    });
  } finally { socket.close(); }
}

const orchestration = ["orchestration:read", "orchestration:operate"];
const gate = "confirm";
const writer = "w18-approved";
const shadow = "w18-draft";
const foreign = "w18-other-project";
const issue = async (token, type, fields) => {
  return rpc(token, "orchestration.dispatchCommand", { type, commandId: randomUUID(), ...fields });
};
const list = token => rpc(token, "workflows.subscribe", {}, { first: true });
const get = (token, runId) => rpc(token, "workflows.get", { runId });

async function projectSpace(owner, name) {
  const projectId = randomUUID();
  const threadId = randomUUID();
  await rpc(owner, "projects.mutate", {
    type: "project.create", commandId: randomUUID(), projectId, title: name,
    workspaceRoot: join(engineHome, name), createWorkspaceRootIfMissing: true,
  });
  await issue(owner, "thread.create", {
    threadId, projectId, title: name, titleRenamed: true, createdBy: "user", creationSource: "mobile",
    modelSelection: { instanceId: "codex", model: "gpt-5.2" },
    runtimeMode: "approval-required", interactionMode: "default", branch: null, worktreePath: null,
  });
  return { projectId, threadId };
}

function definition({ name, time, day, threadId }) {
  return `T3.workflow(${JSON.stringify(name)}, {
    version: 1, payload: T3.Tick, returns: Schema.String,
    ${time ? `triggers: [T3.daily(${JSON.stringify(time)}, { weekdays: [${day}] })],` : ""}
    asks: { routine: "Routine" },
  }, () => Effect.gen(function* () {
    const answer = yield* T3.ask(${JSON.stringify(gate)}, {
      title: "Keep the disposable result?", kind: "routine", choices: ["Allow", "Skip"],
      data: { threadId: ${JSON.stringify(threadId)} },
    });
    return Option.match(answer, { onNone: () => "timeout", onSome: answer => answer.choice });
  }));\n`;
}
function pausedDefinition(name) {
  return `T3.workflow(${JSON.stringify(name)}, { version: 2, payload: T3.Tick },
    () => T3.skip("Routine paused"));\n`;
}
async function save(token, name, source, options) {
  return rpc(token, "workflows.saveDefinition", { name: name + ".ts", source }, options);
}
async function manualStart(name, key) {
  const { stdout } = await engineCall(["workflow", "start", "--base-dir", engineHome, "--json", "--key", key,
    "--input", JSON.stringify({ scheduledAt: new Date().toISOString() }), name], "workflow start");
  return JSON.parse(stdout).run.runId;
}
const readEnvironment = async () => {
  const response = await fetch(`${origin}/.well-known/t3/environment`, { signal: timeoutSignal(5000) });
  assert.ok(response.ok, "Environment probe failed");
  return (await response.json()).environmentId;
};

let stop;
try {
  console.log(`T3 ${pin.version} on disposable loopback`);
  await writeFile(join(engineHome, ".bash_profile"), `export PATH=${env.PATH}\n`);
  stop = await start();
  const environmentId = await readEnvironment();
  assert.ok(environmentId);
  const owner = await pair("Disposable owner");
  const peer = await pair("Disposable operator", orchestration);
  const reader = await pair("Disposable reader", ["orchestration:read"]);
  assert.ok(["filesystem:read", "terminal:operate", ...orchestration].every(scope => owner.scopes.includes(scope)));
  assert.deepEqual([...peer.scopes].sort(), [...orchestration].sort());
  assert.deepEqual(reader.scopes, ["orchestration:read"]);
  const settings = (await rpc(owner, "server.getConfig")).settings;
  assert.equal(settings.workflowsEnabled, false, "Workflows must default off");
  await rpc(owner, "server.updateSettings", { patch: { workflowsEnabled: true } });
  assert.equal((await rpc(owner, "server.getConfig")).settings.workflowsEnabled, true);
  console.log("PASS: Workflows default off and require a separate host-owner opt-in");

  const owned = await projectSpace(owner, "Owned Space");
  const other = await projectSpace(owner, "Other Space");
  for (const { threadId } of [owned, other]) {
    const title = "Changed by the existing thread operation";
    await assert.rejects(issue(reader, "thread.metadata.update", { threadId, title }), /orchestration:operate/);
    const change = await issue(peer, "thread.metadata.update", { threadId, title });
    assert.ok(Number.isInteger(change.sequence));

    const message = {
      threadId, messageId: randomUUID(), text: "Disposable authorization check", attachments: [],
      createdBy: "user", creationSource: "mobile", dispatchMode: { type: "start_immediately" },
    };
    await assert.rejects(issue(reader, "message.dispatch", message), /orchestration:operate/);
    const admission = await issue(peer, "message.dispatch", message);
    assert.ok(Number.isInteger(admission.sequence));
  }
  console.log("PASS: an existing orchestration operator can send to and rename threads in both projects");

  // Two equal-time fixtures distinguish a draft at a real due time from a triggered run.
  const due = new Date(Math.ceil((Date.now() + 35_000) / 60_000) * 60_000);
  const clock = { time: due.toISOString().slice(11, 16), day: due.getUTCDay() };
  const draft = { name: shadow, ...clock, ...owned };
  const active = { name: writer, ...clock, ...owned };
  const draftFile = join(engineHome, "proposal.json");
  await writeFile(draftFile, JSON.stringify(draft));
  const activeSource = definition(active);
  await assert.rejects(save(peer, writer, activeSource), /terminal:operate/);
  await assert.rejects(save(reader, writer, activeSource), /terminal:operate/);
  assert.deepEqual((await list(owner)).workflows, []);
  console.log(`PASS: a proposal is data, and a non-authoring session cannot install its definition (due ${due.toISOString()})`);

  // One explicit approval for the active fixture. The check discards the first response.
  await assert.rejects(save(owner, writer, activeSource, { drop: true }), /Response dropped by fixture/);
  const files = await rpc(owner, "workflows.getDefinition");
  const installed = files.files.find(file => file.name === writer + ".ts");
  assert.equal(installed?.source, activeSource);
  assert.deepEqual(installed.workflows, [writer + "@1"]);
  assert.deepEqual(installed.problems, []);
  await until(async () => (await list(owner)).workflows.some(workflow => workflow.name === writer), "active definition", 10);
  console.log("PASS: reconnect readback found exactly the approved revision after the write response was lost");

  assert.ok(Date.now() < due.valueOf(), "the restart must happen before the due time");
  await stop();
  stop = await start();
  assert.equal(await readEnvironment(), environmentId);
  assert.ok(Date.now() < due.valueOf(), "reconnection must happen before the due time");
  const snapshot = await until(async () => {
    const latest = await list(owner);
    return latest.runs.some(run => run.workflow === writer && run.status === "waiting") && latest;
  }, "exactly one scheduled run after restart", 120);
  const runs = snapshot.runs.filter(run => run.workflow === writer);
  assert.equal(runs.length, 1);
  assert.equal(runs[0].version, 1);
  assert.ok(Date.parse(runs[0].startedAt) >= due.valueOf());
  assert.equal(snapshot.workflows.some(item => item.name === shadow), false);
  assert.equal(snapshot.runs.some(run => run.workflow === shadow), false);
  assert.equal((await rpc(owner, "workflows.getDefinition")).files.some(file => file.name === shadow + ".ts"), false);
  assert.deepEqual(JSON.parse(await readFile(draftFile, "utf8")), draft);
  const runId = runs[0].runId;
  console.log("PASS: the approved fixture ran once after restart; the equal-time draft was still inert after its due time");

  const shadowWrite = await save(owner, shadow, definition(draft));
  assert.deepEqual(shadowWrite, { changed: true, problems: [] });
  assert.equal((await list(owner)).runs.some(run => run.workflow === shadow), false);
  assert.deepEqual(await rpc(owner, "workflows.deleteDefinition", { name: shadow + ".ts" }), { changed: true, problems: [] });
  console.log("PASS: explicitly turning on the original draft after its due time registered it without backfill");

  assert.deepEqual(await save(owner, foreign, definition({ name: foreign, ...other })), { changed: true, problems: [] });
  const foreignRunId = await manualStart(foreign, "other-project");
  await until(async () => (await list(owner)).questions.some(question => question.runId === foreignRunId), "other project's question", 15);

  // Model Botto's trusted installation lookup and validate the paired project before exposing run data.
  const install = { environmentId, projectId: owned.projectId, workflow: writer };
  async function ownedView(connection, caller) {
    if (connection.environmentId !== install.environmentId || connection.projectId !== install.projectId) {
      throw Error("Routine belongs to a different environment or project");
    }
    const latest = await list(caller);
    const ownedRuns = latest.runs.filter(run => run.workflow === install.workflow);
    const ids = new Set(ownedRuns.map(run => run.runId));
    return { runs: ownedRuns, questions: latest.questions.filter(question => ids.has(question.runId)) };
  }
  async function answerOwned(connection, caller, answer) {
    const { questions } = await ownedView(connection, caller);
    if (!questions.some(question => question.runId === answer.runId && question.name === answer.name)) {
      throw Error("Routine question is outside the current project or no longer open");
    }
    await rpc(caller, "workflows.answer", answer);
  }
  await assert.rejects(ownedView({ ...install, projectId: other.projectId }, owner), /different/);
  await assert.rejects(ownedView({ ...install, environmentId: randomUUID() }, owner), /different/);
  assert.deepEqual((await ownedView(install, owner)).questions.map(question => question.runId), [runId]);
  await assert.rejects(answerOwned(install, owner, { runId: foreignRunId, name: gate, choice: "Allow" }), /outside/);
  assert.equal((await get(owner, foreignRunId)).run.status, "waiting");
  const ownAnswer = { runId, name: gate, choice: "Allow" };
  await assert.rejects(answerOwned(install, reader, ownAnswer), /orchestration:operate/);
  assert.equal((await get(reader, runId)).run.status, "waiting");
  assert.equal((await get(peer, runId)).run.status, "waiting");
  await rpc(peer, "workflows.answer", { ...ownAnswer, runId: foreignRunId });
  const otherDetail = await until(async () => {
    const detail = await get(owner, foreignRunId);
    return detail.run.status === "completed" && detail;
  }, "operator's environment-wide answer", 12);
  assert.equal(otherDetail.steps.find(step => step.name === gate).result.answeredBy, "Disposable operator");
  console.log("PASS: Botto-style project filtering hides the other run and refuses its answer; read-only cannot answer");
  console.log("LIMIT: raw T3 orchestration operators retain environment-wide read and answer authority");

  const replaced = await save(owner, writer, activeSource + pausedDefinition(writer));
  assert.deepEqual(replaced, { changed: true, problems: [] });
  const paused = (await list(owner)).workflows.find(workflow => workflow.name === writer);
  assert.equal(paused.version, 2);
  assert.deepEqual(paused.triggers, []);
  const waiting = await get(owner, runId);
  assert.equal(waiting.run.version, 1);
  assert.equal(waiting.run.status, "waiting");
  const deleteWhileWaiting = await rpc(owner, "workflows.deleteDefinition", { name: writer + ".ts" });
  assert.equal(deleteWhileWaiting.changed, false);
  console.log("PASS: a paused revision removed future triggers and preserved the waiting run");

  const manualId = await manualStart(writer, "paused-manual");
  const skipped = await until(async () => {
    const detail = await get(owner, manualId);
    return detail.run.status === "skipped" && detail;
  }, "paused manual run to skip", 12);
  assert.equal(skipped.run.version, 2);
  assert.deepEqual(skipped.steps, []);
  await answerOwned(install, owner, ownAnswer);
  const completed = await until(async () => {
    const detail = await get(owner, runId);
    return detail.run.status === "completed" && detail;
  }, "original run to finish after pause", 12);
  assert.equal(completed.run.result, "Allow");
  assert.equal(completed.steps.find(step => step.name === gate).result.answeredBy, "Disposable owner");
  await assert.rejects(answerOwned(install, owner, ownAnswer), /no longer open/);
  const history = (await list(owner)).runs.filter(run => run.workflow === writer);
  assert.deepEqual(new Set(history.map(run => run.runId)), new Set([runId, manualId]));
  assert.deepEqual(await rpc(owner, "workflows.deleteDefinition", { name: writer + ".ts" }), { changed: true, problems: [] });
  assert.equal((await get(owner, runId)).run.result, "Allow");
  console.log("PASS: pause skipped a manual start; the in-progress run finished once, and deleting kept its history");
} finally {
  if (stop) await stop();
  await rm(engineHome, { recursive: true, force: true });
}
console.log("Stopped the disposable engine and removed its home.");
