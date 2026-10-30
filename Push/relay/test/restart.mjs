import assert from "node:assert/strict";
import { generateKeyPairSync, createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { Miniflare, Response as ProviderResponse, convertV4MiniflareOptions } from "miniflare";

test("the deployed bundle resumes queued work and retains revocation across runtime restarts", { timeout: 30_000 }, async () => {
  const persist = await mkdtemp(join(tmpdir(), "botto-relay-restart-"));
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256", privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
  const capability = "ab".repeat(32);
  const installation = createHash("sha256").update(capability).digest("hex");
  const device = "01".repeat(16);
  const now = Math.floor(Date.now() / 1000);
  const registration = { v: 1, generation: 1, token: "cd".repeat(32), bundle_id: "com.sree.botto", environment: "sandbox",
    preferences: { replies: true, requests: true, failures: true, previews: true }, visible_chat: null, visible_until: 0 };
  const event = { v: 1, event_id: "11".repeat(32), thread_id: "22".repeat(32), kind: "reply", request_id: null,
    created_at: now, expires_at: now + 3600, targets: [{ device_id: device, generation: 1, sealed: Buffer.from("x".repeat(80)).toString("base64") }] };
  const outgoing = [];
  let providerError;
  const start = () => new Miniflare(convertV4MiniflareOptions({
    name: "botto-relay-restart-proof", modules: true, scriptPath: ".artifacts/deploy/worker.js",
    compatibilityDate: "2026-10-29", compatibilityFlags: ["nodejs_compat"],
    resourcePersistencePath: persist, logRequests: false,
    durableObjects: { INSTALLATIONS: { className: "Installation", useSQLite: true } },
    ratelimits: { REQUEST_LIMITER: { namespace_id: "1001", simple: { limit: 120, period: 60 } } },
    bindings: { ALLOWED_BUNDLE_IDS: "com.sree.botto", ALLOWED_ENVIRONMENTS: "sandbox,production", APNS_TEAM_ID: "TESTTEAM01", APNS_KEY_ID: "TESTKEY001", APNS_PRIVATE_KEY: privateKey },
    outboundService: async request => {
      try {
      assert.equal(request.url, `https://api.sandbox.push.apple.com/3/device/${registration.token}`);
      const body = await request.json();
      assert.equal(body.botto.sealed, event.targets[0].sealed);
      assert.deepEqual(body.aps.alert, { title: "Botto", body: "New activity" });
      outgoing.push(body);
      return outgoing.length === 1 ? ProviderResponse.json({ reason: "ServiceUnavailable" }, { status: 503 }) : new ProviderResponse(null, { status: 200 });
      } catch (error) { providerError = error; throw error; }
    },
  }));
  let runtime;
  const call = async (suffix, method, body) => {
    const response = await runtime.dispatchFetch(`https://relay.test/v1/installations/${installation}${suffix}`, {
      method, headers: { Authorization: `Bearer ${capability}`, "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  try {
    runtime = start();
    assert.equal((await call(`/devices/${device}`, "PUT", registration)).status, "accepted");
    const initial = await call("/events", "POST", event);
    if (providerError) throw providerError;
    assert.equal(initial.status, "queued");
    assert.equal(outgoing.length, 1);
    await runtime.dispose();
    runtime = start();
    // No synthetic alarm or state accessor: restart the built Worker and observe
    // its persisted alarm submit the queued notification through normal egress.
    await runtime.ready;
    const deadline = Date.now() + 12_000;
    while (outgoing.length < 2 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(outgoing.length, 2);
    assert.equal((await call("/events", "POST", event)).status, "duplicate");
    assert.equal((await call(`/devices/${device}/revoke`, "POST", { v: 1, generation: 2 })).status, "accepted");
    await runtime.dispose();
    runtime = start();
    assert.equal((await call(`/devices/${device}`, "PUT", registration)).status, "stale");
    assert.equal((await call("/events", "POST", { ...event, event_id: "33".repeat(32) })).status, "revoked");
    assert.equal(outgoing.length, 2);
  } finally {
    await runtime?.dispose();
    await rm(persist, { recursive: true, force: true });
  }
});

test("queued cancellation and revocation survive restart without retrying or replacing their recipients", { timeout: 30_000 }, async t => {
  const persist = await mkdtemp(join(tmpdir(), "botto-relay-queued-retirement-"));
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256", privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
  const capability = "ef".repeat(32);
  const installation = createHash("sha256").update(capability).digest("hex");
  const questionDevice = "01".repeat(16), replyDevice = "02".repeat(16);
  const originalQuestionToken = "cd".repeat(32), originalReplyToken = "ef".repeat(32), newReplyToken = "12".repeat(32);
  const now = Math.floor(Date.now() / 1000);
  const cancelledEvent = "11".repeat(32), revokedEvent = "22".repeat(32), freshQuestionEvent = "33".repeat(32), freshReplyEvent = "44".repeat(32);
  const requestID = "55".repeat(32);
  const makeRegistration = (token, generation = 1) => ({ v: 1, generation, token, bundle_id: "com.sree.botto", environment: "sandbox",
    preferences: { replies: true, requests: true, failures: true, previews: true }, visible_chat: null, visible_until: 0 });
  const makeEvent = (eventID, deviceID, generation = 1, waiting = false) => ({ v: 1, event_id: eventID, thread_id: "66".repeat(32),
    kind: waiting ? "question" : "reply", request_id: waiting ? requestID : null, created_at: now, expires_at: now + (waiting ? 300 : 3600),
    targets: [{ device_id: deviceID, generation, sealed: Buffer.from("x".repeat(80)).toString("base64") }] });
  const question = makeEvent(cancelledEvent, questionDevice, 1, true);
  const reply = makeEvent(revokedEvent, replyDevice);
  const attempts = [];
  let providerError;
  const start = () => new Miniflare(convertV4MiniflareOptions({
    name: "botto-relay-queued-retirement-proof", modules: true, scriptPath: ".artifacts/deploy/worker.js",
    compatibilityDate: "2026-10-29", compatibilityFlags: ["nodejs_compat"],
    resourcePersistencePath: persist, logRequests: false,
    durableObjects: { INSTALLATIONS: { className: "Installation", useSQLite: true } },
    ratelimits: { REQUEST_LIMITER: { namespace_id: "1001", simple: { limit: 120, period: 60 } } },
    bindings: { ALLOWED_BUNDLE_IDS: "com.sree.botto", ALLOWED_ENVIRONMENTS: "sandbox,production", APNS_TEAM_ID: "TESTTEAM01", APNS_KEY_ID: "TESTKEY001", APNS_PRIVATE_KEY: privateKey },
    outboundService: async request => {
      try {
        const body = await request.json();
        attempts.push({ url: request.url, event: body.botto.event_id, device: body.botto.device_id, generation: body.botto.generation });
        assert.equal(request.method, "POST");
        if (body.botto.event_id === cancelledEvent || body.botto.event_id === revokedEvent) {
          return ProviderResponse.json({ reason: "ServiceUnavailable" }, { status: 503 });
        }
        assert([freshQuestionEvent, freshReplyEvent].includes(body.botto.event_id));
        return new ProviderResponse(null, { status: 200 });
      } catch (error) { providerError = error; throw error; }
    },
  }));
  let runtime;
  const call = async (suffix, method, body) => {
    const response = await runtime.dispatchFetch(`https://relay.test/v1/installations/${installation}${suffix}`, {
      method, headers: { Authorization: `Bearer ${capability}`, "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  try {
    runtime = start();
    assert.equal((await call(`/devices/${questionDevice}`, "PUT", makeRegistration(originalQuestionToken))).status, "accepted");
    assert.equal((await call(`/devices/${replyDevice}`, "PUT", makeRegistration(originalReplyToken))).status, "accepted");
    assert.equal((await call("/events", "POST", question)).status, "queued");
    assert.equal((await call("/events", "POST", reply)).status, "queued");
    assert.equal(attempts.length, 2);
    assert.equal((await call("/cancellations", "POST", { v: 1, request_id: requestID, expires_at: now + 300 })).status, "accepted");
    assert.equal((await call(`/devices/${replyDevice}/revoke`, "POST", { v: 1, generation: 2 })).status, "accepted");
    await runtime.dispose();
    runtime = start();
    await runtime.ready;
    // Actual wall time crosses the five-second first-retry interval. No alarm or
    // state accessor is invoked: the bundled runtime owns all persisted wakeups.
    await new Promise(resolve => setTimeout(resolve, 6100));
    assert.equal(providerError, undefined);
    assert.deepEqual(attempts, [
      { url: `https://api.sandbox.push.apple.com/3/device/${originalQuestionToken}`, event: cancelledEvent, device: questionDevice, generation: 1 },
      { url: `https://api.sandbox.push.apple.com/3/device/${originalReplyToken}`, event: revokedEvent, device: replyDevice, generation: 1 },
    ]);
    assert.equal((await call("/events", "POST", question)).status, "duplicate");
    assert.equal((await call("/events", "POST", reply)).status, "duplicate");
    assert.equal((await call(`/devices/${replyDevice}`, "PUT", makeRegistration(originalReplyToken))).status, "stale");

    const freshQuestion = { ...makeEvent(freshQuestionEvent, questionDevice, 1, true), request_id: "77".repeat(32) };
    assert.equal((await call("/events", "POST", freshQuestion)).status, "accepted");
    assert.equal((await call(`/devices/${replyDevice}`, "PUT", makeRegistration(newReplyToken, 3))).status, "accepted");
    assert.equal((await call("/events", "POST", makeEvent(freshReplyEvent, replyDevice, 3))).status, "accepted");
    assert.equal(providerError, undefined);
    assert.deepEqual(attempts.slice(2), [
      { url: `https://api.sandbox.push.apple.com/3/device/${originalQuestionToken}`, event: freshQuestionEvent, device: questionDevice, generation: 1 },
      { url: `https://api.sandbox.push.apple.com/3/device/${newReplyToken}`, event: freshReplyEvent, device: replyDevice, generation: 3 },
    ]);
    t.diagnostic("Provider proof: two initial rejections; zero retired retries after restart/6.1s; two fresh accepted controls at the correct original/new targets.");
  } finally {
    await runtime?.dispose();
    await rm(persist, { recursive: true, force: true });
  }
});
