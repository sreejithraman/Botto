import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { fork, execFileSync } from 'node:child_process';
import { readFile, writeFile, appendFile, mkdtemp, mkdir, rm, lstat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const testRoot = fileURLToPath(new URL('.', import.meta.url));
const relayRoot = resolve(testRoot, '..');
const artifact = join(relayRoot, '.artifacts/crash');
await mkdir(artifact, { recursive: true });
assert.notEqual(process.platform, 'win32', 'controlled process-group crashes require a POSIX test host');
const bundle = join(relayRoot, '.artifacts/deploy/worker.js');
const childFile = join(testRoot, 'fixtures/crash-child.mjs');
const providerEntry = join(testRoot, 'fixtures/provider-entry.mjs');
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const bundleHash = sha256(await readFile(bundle));
const sourceFiles = ['src/installation.ts', 'src/apns.ts', 'src/protocol.ts', 'src/worker.ts', 'src/policy.ts', 'src/env.ts', 'package-lock.json'];
const sourceHashes = Object.fromEntries(await Promise.all(sourceFiles.map(async path => [path, sha256(await readFile(join(relayRoot, path)))])));
const harnessHashes = Object.fromEntries(await Promise.all(['test/crash.mjs', 'test/fixtures/crash-child.mjs', 'test/fixtures/provider-entry.mjs'].map(async path => [path, sha256(await readFile(join(relayRoot, path)))])));
const timeout = (promise, label, ms = 8000) => {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timeout:${label}`)), ms); })]).finally(() => clearTimeout(timer));
};
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const runs = [];
const live = new Set();
let interrupted;
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => { interrupted = signal; });
const checkInterruption = () => { if (interrupted) throw new Error(`fixture_interrupted:${interrupted}`); };

function launch(config) {
  const child = fork(childFile, [], {
    detached: true, stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    env: Object.fromEntries(['PATH', 'HOME', 'TMPDIR', 'TEMP', 'TMP'].filter(key => process.env[key]).map(key => [key, process.env[key]])),
  });
  live.add(child);
  const messages = [];
  let stdout = '', stderr = '';
  const pending = new Map();
  let sequence = 0;
  child.stdout.on('data', value => { stdout += value; });
  child.stderr.on('data', value => { stderr += value; });
  child.on('message', message => {
    messages.push({ ...message, observedAt: new Date().toISOString() });
    if (message.id && pending.has(message.id)) {
      const callback = pending.get(message.id); pending.delete(message.id);
      if (message.type === 'error') callback.reject(new Error(message.message));
      else callback.resolve(message);
    }
  });
  child.on('exit', (code, signal) => {
    live.delete(child);
    for (const callback of pending.values()) callback.reject(new Error(`owned_child_exited:${code}:${signal}`));
    pending.clear();
  });
  const waitFor = async (predicate, label, ms = 8000) => timeout((async () => {
    const deadline = Date.now() + ms;
    while (true) {
      checkInterruption();
      const value = messages.find(predicate);
      if (value) return value;
      const failure = messages.find(m => m.type === 'error');
      if (failure) throw new Error(`child:${failure.message}`);
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(`child_exited:${label}:${stderr}`);
      if (Date.now() >= deadline) throw new Error(`timeout:${label}`);
      await delay(10);
    }
  })(), label, ms);
  child.send({ type: 'start', config });
  const ready = waitFor(m => m.type === 'ready', 'child_ready');
  const call = async (suffix, method, body) => {
    const id = ++sequence;
    const result = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    // A crash is intentional in this harness. Attach a rejection handler before
    // returning the promise so it cannot become an unhandled rejection.
    result.catch(() => {});
    child.send({ type: 'call', id, url: `https://relay.test/v1/installations/${config.installation}${suffix}`, method,
      headers: { Authorization: `Bearer ${config.capability}`, 'Content-Type': 'application/json' }, body });
    return result;
  };
  return { child, messages, ready, call, waitFor, logs: () => ({ stdout, stderr }) };
}

async function terminate(runtime, reason) {
  const { child } = runtime;
  const pid = child.pid;
  assert(live.has(child), 'only a known live fixture child may be killed');
  // Parent-group termination must not interrupt the ownership inspection itself.
  const processRow = execFileSync('ps', ['-o', 'pid=,pgid=,command=', '-p', String(pid)], { encoding: 'utf8', detached: true }).trim();
  const [reportedPID, groupID] = processRow.split(/\s+/).map(Number);
  assert.equal(reportedPID, pid);
  assert.equal(groupID, pid, 'detached child must lead its own process group');
  assert(processRow.includes(childFile), 'PID command must match the owned fixture');
  const allBefore = execFileSync('ps', ['-Ao', 'pid=,ppid=,pgid=,stat=,command='], { encoding: 'utf8', detached: true }).split('\n').filter(Boolean);
  const descendantIDs = new Set([pid]);
  for (;;) {
    let added = false;
    for (const line of allBefore) {
      const [processID, parentID] = line.trim().split(/\s+/).map(Number);
      if (descendantIDs.has(parentID) && !descendantIDs.has(processID)) { descendantIDs.add(processID); added = true; }
    }
    if (!added) break;
  }
  const ownedRows = allBefore.filter(line => descendantIDs.has(Number(line.trim().split(/\s+/)[0])));
  const hadWorkerdProcess = ownedRows.some(line => line.includes('/workerd '));
  assert(ownedRows.every(line => Number(line.trim().split(/\s+/)[2]) === pid), 'every owned runtime descendant must be in the isolated child group');
  const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));
  process.kill(-pid, 'SIGKILL');
  const exit = await timeout(exited, 'owned_child_exit');
  // Reap the direct child and allow its runtime descendants to leave the group.
  const deadline = Date.now() + 5000;
  let remaining = '';
  do {
    remaining = execFileSync('ps', ['-Ao', 'pid=,pgid=,stat=,command='], { encoding: 'utf8', detached: true }).split('\n')
      .filter(line => Number(line.trim().split(/\s+/)[1]) === pid && !line.trim().split(/\s+/)[2]?.startsWith('Z')).join('\n');
    if (!remaining) break;
    await delay(25);
  } while (Date.now() < deadline);
  assert.equal(remaining, '', 'no live owned runtime process may survive group termination');
  return { reason, pid, groupID, processRow, ownedProcessTree: ownedRows, hadWorkerdProcess,
    exit, noLiveGroupMembers: true, killedAt: new Date().toISOString() };
}

async function scenario(name, mode) {
  const persistence = await mkdtemp(join(tmpdir(), 'botto-push-crash-'));
  const capability = randomBytes(32).toString('hex');
  const installation = sha256(capability);
  const device = randomBytes(16).toString('hex');
  const deviceToken = 'cd'.repeat(32);
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256', privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } });
  const provider = { initiated: 0, accepted: 0, responseReturned: 0, checkpointReached: 0, attempts: [] };
  const journalPath = join(artifact, `${name}.provider.jsonl`);
  await writeFile(journalPath, '');
  const responses = new Set();
  const server = createServer(async (request, response) => {
    try {
    responses.add(response);
    response.on('close', () => responses.delete(response));
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const forwarded = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (forwarded.url === 'https://botto-crash-checkpoint.invalid/after-provider-200-before-receipt') {
      assert.equal(mode, 'cancel_probe');
      assert.equal(forwarded.method, 'POST');
      await appendFile(journalPath, `${JSON.stringify({ phase: 'workerd_provider200_body_cancel_checkpoint', observedAt: new Date().toISOString() })}\n`);
      provider.checkpointReached++;
      return;
    }
    assert.equal(forwarded.url, `https://api.sandbox.push.apple.com/3/device/${deviceToken}`);
    assert.equal(forwarded.method, 'POST');
    assert.equal(forwarded.body.botto.event_id, event.event_id);
    assert.equal(forwarded.body.botto.device_id, device);
    assert.equal(forwarded.body.botto.sealed, event.targets[0].sealed);
    const attempt = { eventID: forwarded.body.botto.event_id, bodyHash: sha256(JSON.stringify(forwarded.body)), observedAt: new Date().toISOString() };
    await appendFile(journalPath, `${JSON.stringify({ phase: 'initiated', attempt })}\n`);
    provider.initiated++;
    provider.attempts.push(attempt);
    if (mode !== 'before_acceptance') {
      await appendFile(journalPath, `${JSON.stringify({ phase: 'accepted', eventID: attempt.eventID, observedAt: new Date().toISOString() })}\n`);
      provider.accepted++;
    }
    if (mode === 'before_acceptance' || mode === 'accepted_response_held') return;
    provider.responseReturned++;
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{}');
    } catch (error) {
      provider.fixtureError = error.message;
      response.writeHead(500, { 'content-type': 'application/json' }); response.end('{"fixture_error":true}');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const config = { relayRoot, bundle, providerEntry, workspace: relayRoot, persistence, privateKey, capability, installation, deviceToken,
    providerURL: `http://127.0.0.1:${address.port}/provider`, holdEventAck: mode === 'ack_held', cancelProbe: mode === 'cancel_probe' };
  const now = Math.floor(Date.now() / 1000);
  const registration = { v: 1, generation: 1, token: deviceToken, bundle_id: 'com.sree.botto', environment: 'sandbox',
    preferences: { replies: true, requests: true, failures: true, previews: true }, visible_chat: null, visible_until: 0 };
  const event = { v: 1, event_id: randomBytes(32).toString('hex'), thread_id: randomBytes(32).toString('hex'), kind: 'reply', request_id: null,
    created_at: now, expires_at: now + 3600, targets: [{ device_id: device, generation: 1, sealed: Buffer.from('x'.repeat(80)).toString('base64') }] };
  let runtime;
  const record = { name, mode, bundleHash, workerEntry: mode === 'cancel_probe' ? providerEntry : bundle,
    workerEntryHash: mode === 'cancel_probe' ? harnessHashes['test/fixtures/provider-entry.mjs'] : bundleHash,
    persistence, providerJournal: journalPath,
    startedAt: new Date().toISOString(), phases: [], processCleanup: [], allPhaseMessages: [] };
  await writeFile(join(artifact, `${name}.active.json`), `${JSON.stringify({ persistence, startedAt: record.startedAt }, null, 2)}\n`);
  try {
    runtime = launch(config);
    await runtime.ready;
    const enrollment = await timeout(runtime.call(`/devices/${device}`, 'PUT', registration), 'enrollment');
    assert.equal(enrollment.httpStatus, 200);
    assert.equal(enrollment.body.status, 'accepted');
    const publicCall = runtime.call('/events', 'POST', event);
    let acknowledged = false;
    publicCall.then(() => { acknowledged = true; }, () => {});
    if (mode === 'ack_held') {
      const phase = await runtime.waitFor(m => m.phase === 'public_result_computed_ack_held', 'receipt_public_result');
      assert.equal(phase.observedResult.httpStatus, 200);
      assert.equal(phase.observedResult.body.status, 'accepted');
      record.phases.push(phase);
    } else if (mode === 'cancel_probe') {
      const phase = await runtime.waitFor(m => m.phase === 'provider_body_cancel_entered', 'response_body_cancel', 5000);
      record.phases.push(phase);
      const deadline = Date.now() + 3000;
      while (provider.checkpointReached < 1) {
        checkInterruption();
        if (Date.now() >= deadline) throw new Error('timeout:independent_body_cancel_checkpoint');
        await delay(10);
      }
      // The parent journals and holds the workerd-local cancellation promise.
      await delay(200);
      assert.equal(acknowledged, false, 'the workerd-local cancellation promise must hold completion');
      record.controlled = true;
    } else {
      await timeout((async () => {
        const deadline = Date.now() + 8000;
        while (provider.initiated < 1 || provider.accepted !== (mode === 'before_acceptance' ? 0 : 1)) {
          checkInterruption();
          if (provider.fixtureError) throw new Error(`provider_fixture:${provider.fixtureError}`);
          if (Date.now() >= deadline) throw new Error('timeout:provider_initiation');
          await delay(10);
        }
      })(), 'provider_initiation');
      record.phases.push({ phase: mode, observedAt: new Date().toISOString() });
    }
    assert.equal(provider.initiated, 1);
    assert.equal(provider.accepted, mode === 'before_acceptance' ? 0 : 1);
    assert.equal(acknowledged, false, 'the original caller must not receive its acknowledgment');
    record.beforeCrash = { initiated: provider.initiated, accepted: provider.accepted, responseReturned: provider.responseReturned,
      checkpointReached: provider.checkpointReached, originalCallAcknowledged: acknowledged };
    record.allPhaseMessages.push(...runtime.messages.filter(m => m.type === 'phase'));
    record.processCleanup.push(await terminate(runtime, 'intentional crash at observed public/provider phase'));
    assert.equal(record.processCleanup.at(-1).hadWorkerdProcess, true, 'a claimed runtime crash must include the actual workerd child');
    await publicCall.catch(() => {});
    runtime = undefined;
    for (const response of responses) response.destroy();
    runtime = launch({ ...config, holdEventAck: false, cancelProbe: false });
    await runtime.ready;
    const replay = await timeout(runtime.call('/events', 'POST', event), 'replay');
    assert.equal(replay.httpStatus, 200);
    assert.equal(replay.body.status, 'duplicate');
    // The known transient-retry delay is five seconds. Observe beyond it so a
    // mistaken queued recovery cannot hide behind an immediate duplicate reply.
    await delay(6000);
    checkInterruption();
    assert.equal(provider.initiated, 1, 'a retained unresolved claim/receipt must not blindly initiate a second provider send');
    assert.equal(provider.accepted, mode === 'before_acceptance' ? 0 : 1);
    const removal = await timeout(runtime.call(`/devices/${device}/revoke`, 'POST', { v: 1, generation: 2 }), 'post_crash_removal');
    assert.equal(removal.httpStatus, 200);
    assert.equal(removal.body.status, 'accepted');
    const afterRemoval = await timeout(runtime.call('/events', 'POST', { ...event, event_id: randomBytes(32).toString('hex') }), 'post_removal_event');
    assert.equal(afterRemoval.httpStatus, 200);
    assert.equal(afterRemoval.body.status, 'revoked');
    assert.equal(provider.initiated, 1, 'acknowledged removal after recovery must fence new sends');
    record.replay = replay;
    record.removal = removal;
    record.postRemovalEvent = afterRemoval;
    record.afterReplay = { initiated: provider.initiated, accepted: provider.accepted, responseReturned: provider.responseReturned, checkpointReached: provider.checkpointReached };
    record.quietObservationMilliseconds = 6000;
    record.providerAttempts = provider.attempts;
    record.passed = true;
    record.processCleanup.push(await terminate(runtime, 'fixture finished'));
    runtime = undefined;
  } catch (error) {
    record.passed = false;
    record.error = { name: error.name, message: error.message, stack: error.stack };
    if (runtime) { record.childDiagnostics = runtime.logs(); record.allPhaseMessages.push(...runtime.messages.filter(m => m.type === 'phase')); }
    record.providerCountsAtFailure = { initiated: provider.initiated, accepted: provider.accepted, responseReturned: provider.responseReturned };
    if (mode === 'cancel_probe') record.limitation = 'A workerd-local public provider-response wrapper was used. If its checkpoint cannot hold the source sender, this run does not prove provider200-before-receipt behavior.';
  } finally {
    if (runtime && live.has(runtime.child)) record.processCleanup.push(await terminate(runtime, 'failure cleanup'));
    for (const response of responses) response.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(persistence, { recursive: true, force: true });
    await assert.rejects(lstat(persistence), { code: 'ENOENT' });
    record.persistenceRemoved = true;
    await rm(join(artifact, `${name}.active.json`), { force: true });
    record.finishedAt = new Date().toISOString();
    runs.push(record);
    await writeFile(join(artifact, `${name}.json`), `${JSON.stringify(record, null, 2)}\n`);
    console.log(JSON.stringify({ name, passed: record.passed, beforeCrash: record.beforeCrash, afterReplay: record.afterReplay, error: record.error?.message, limitation: record.limitation }));
  }
}

const selected = process.argv[2] ?? 'all';
const scenarios = [
  ['claim_before_provider_acceptance', 'before_acceptance'],
  ['provider_accepted_response_held', 'accepted_response_held'],
  ['provider_response_before_receipt', 'cancel_probe'],
  ['receipt_persisted_ack_held', 'ack_held'],
];
assert(selected === 'all' || scenarios.some(([, mode]) => mode === selected), 'unknown fixture scenario');
for (const [name, mode] of scenarios) {
  if (interrupted) break;
  if (selected === 'all' || selected === mode) await scenario(name, mode);
}

const identity = { bundle, bundleHash, sourceHashes, harnessHashes, node: process.version,
  miniflareVersion: JSON.parse(await readFile(join(relayRoot, 'node_modules/miniflare/package.json'), 'utf8')).version,
  workerdVersion: JSON.parse(await readFile(join(relayRoot, 'node_modules/workerd/package.json'), 'utf8')).version };
const required = runs;
assert.equal(sha256(await readFile(bundle)), bundleHash, 'frozen bundle must remain unchanged');
for (const [path, hash] of Object.entries(sourceHashes)) assert.equal(sha256(await readFile(join(relayRoot, path))), hash, `frozen input changed: ${path}`);
for (const [path, hash] of Object.entries(harnessHashes)) assert.equal(sha256(await readFile(join(relayRoot, path))), hash, `harness input changed during run: ${path}`);
assert.equal(live.size, 0);
const report = { identity, runs, requiredPassing: !interrupted && required.length === (selected === 'all' ? scenarios.length : 1) && required.every(run => run.passed), noKnownLiveChildren: live.size === 0,
  interpretation: 'duplicate proves retained deduplication state, not provider acceptance; the parent-owned provider fixture supplies independent initiation/acceptance counts. Before-acceptance loss is deliberately permitted under unresolved-send ambiguity.' };
await writeFile(join(artifact, selected === 'all' ? 'report.json' : `report-${selected}.json`), `${JSON.stringify(report, null, 2)}\n`);
assert(report.requiredPassing, 'all required crash phases must pass');
