import { env, exports } from "cloudflare:workers";
import { evictDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, beforeEach, expect, test, vi } from "vitest";

beforeEach(() => { token = [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, "0")).join(""); });
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

let token = "ab".repeat(32);
const device = "01".repeat(16);
async function installID(): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)))].map(b => b.toString(16).padStart(2, "0")).join("");
}
async function call(path: string, method: string, body: unknown, credential = token) {
  const result = await exports.default.fetch(`https://relay.test/v1/installations/${await installID()}${path}`, {
    method,
    headers: { Authorization: `Bearer ${credential}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return new Response(await result.text(), { status: result.status, headers: result.headers });
}
function registration(generation = 1) {
  return { v: 1, generation, token: "cd".repeat(32), bundle_id: "com.sree.botto", environment: "sandbox", preferences: { replies: true, requests: true, failures: true, previews: true }, visible_chat: null, visible_until: 0 };
}
function event(overrides: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return { v: 1, event_id: "11".repeat(32), thread_id: "22".repeat(32), kind: "reply", request_id: null,
    created_at: now, expires_at: now + 3600,
    targets: [{ device_id: device, generation: 1, sealed: btoa("x".repeat(80)) }], ...overrides };
}

test("health is a safe liveness response, not a delivery claim", async () => {
  const response = await exports.default.fetch("https://relay.test/health");
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(await response.json()).toEqual({ v: 1, status: "ok" });
});

test("an enrolled target receives only the sealed preview and safe original alert", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  const requests: { url: string; init: RequestInit }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit) => {
    requests.push({ url, init });
    return new Response(null, { status: 200 });
  }));
  const submitted = event();
  const first = await call("/events", "POST", submitted);
  expect(first.status).toBe(200);
  expect(await first.json()).toMatchObject({ status: "accepted" });
  expect(requests).toHaveLength(1);
  expect(requests[0]?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${"cd".repeat(32)}`);
  const payload = JSON.parse(requests[0]?.init.body as string);
  expect(payload.aps).toEqual({ alert: { title: "Botto", body: "New activity" }, "mutable-content": 1, "thread-id": "22".repeat(32), sound: "default" });
  expect(payload.botto).toEqual({ v: 1, installation_id: await installID(), device_id: device, generation: 1,
    event_id: "11".repeat(32), kind: "reply", expires_at: submitted.expires_at, sealed: btoa("x".repeat(80)) });
  const headers = new Headers(requests[0]?.init.headers);
  expect(headers.get("apns-topic")).toBe("com.sree.botto");
  expect(headers.get("apns-push-type")).toBe("alert");
  const jwt = headers.get("authorization")?.replace("bearer ", "").split(".") ?? [];
  expect(JSON.parse(atob(jwt[0]!.replaceAll("-", "+").replaceAll("_", "/")))).toEqual({ alg: "ES256", kid: "TESTKEY001" });
  expect(JSON.parse(atob(jwt[1]!.replaceAll("-", "+").replaceAll("_", "/"))).iss).toBe("TESTTEAM01");
  expect(atob(jwt[2]!.replaceAll("-", "+").replaceAll("_", "/"))).toHaveLength(64);
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ status: "duplicate" });
  expect(requests).toHaveLength(1);
});

test("authenticated enrollment is idempotent and rejects capability substitution", async () => {
  expect((await call(`/devices/${device}`, "PUT", registration(), "ef".repeat(32))).status).toBe(401);
  const first = await call(`/devices/${device}`, "PUT", registration());
  expect(first.status).toBe(200);
  expect(await first.json()).toMatchObject({ v: 1, status: "accepted" });
  const repeat = await call(`/devices/${device}`, "PUT", registration());
  expect(await repeat.json()).toMatchObject({ status: "duplicate" });
  const conflict = await call(`/devices/${device}`, "PUT", { ...registration(), token: "ef".repeat(32) });
  expect(conflict.status).toBe(409);
});

test("a later target expires while an earlier provider request is pending", async () => {
  const second = "02".repeat(16);
  await call(`/devices/${device}`, "PUT", registration());
  await call(`/devices/${second}`, "PUT", registration());
  const started = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(started * 1000);
  const send = vi.fn(async () => { clock.mockReturnValue((started + 8) * 1000); return new Response(null, { status: 200 }); });
  vi.stubGlobal("fetch", send);
  const submitted = event({ expires_at: started + 5, targets: [
    { device_id: device, generation: 1, sealed: btoa("x".repeat(80)) },
    { device_id: second, generation: 1, sealed: btoa("x".repeat(80)) },
  ] });
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ targets: [
    { device_id: device, status: "accepted" }, { device_id: second, status: "expired" },
  ] });
  expect(send).toHaveBeenCalledTimes(1);
});

test("presence that expires during an earlier provider request cannot suppress a later target", async () => {
  const second = "02".repeat(16), started = Math.floor(Date.now() / 1000);
  await call(`/devices/${device}`, "PUT", registration());
  await call(`/devices/${second}`, "PUT", { ...registration(), visible_chat: "22".repeat(32), visible_until: started + 5 });
  const clock = vi.spyOn(Date, "now").mockReturnValue(started * 1000);
  const send = vi.fn(async () => { clock.mockReturnValue((started + 8) * 1000); return new Response(null, { status: 200 }); });
  vi.stubGlobal("fetch", send);
  const submitted = event({ targets: [
    { device_id: device, generation: 1, sealed: btoa("x".repeat(80)) },
    { device_id: second, generation: 1, sealed: btoa("x".repeat(80)) },
  ] });
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ status: "accepted" });
  expect(send).toHaveBeenCalledTimes(2);
});

test("provider preparation cannot start egress after expiry", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  const started = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(started * 1000);
  const sign = crypto.subtle.sign.bind(crypto.subtle);
  vi.spyOn(crypto.subtle, "sign").mockImplementation(async (...args) => {
    const signature = await sign(...args);
    clock.mockReturnValue((started + 8) * 1000);
    return signature;
  });
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  expect(await (await call("/events", "POST", event({ expires_at: started + 5 }))).json()).toMatchObject({ status: "expired" });
  expect(send).not.toHaveBeenCalled();
});

test("a retry waits from the provider response time", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  const started = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(started * 1000);
  const send = vi.fn(async () => {
    if (send.mock.calls.length === 1) {
      clock.mockReturnValue((started + 8) * 1000);
      return Response.json({ reason: "ServiceUnavailable" }, { status: 503 });
    }
    return new Response(null, { status: 200 });
  });
  vi.stubGlobal("fetch", send);
  expect(await (await call("/events", "POST", event())).json()).toMatchObject({ status: "queued" });
  const stub = env.INSTALLATIONS.getByName(await installID());
  await runDurableObjectAlarm(stub);
  expect(send).toHaveBeenCalledTimes(1);
  clock.mockReturnValue((started + 13) * 1000);
  await runDurableObjectAlarm(stub);
  expect(send).toHaveBeenCalledTimes(2);
});

test("revocation survives eviction and prevents old generations from restoring delivery", async () => {
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  await call(`/devices/${device}`, "PUT", registration());
  expect(await (await call(`/devices/${device}/revoke`, "POST", { v: 1, generation: 2 })).json()).toMatchObject({ status: "accepted" });
  await evictDurableObject(env.INSTALLATIONS.getByName(await installID()));
  expect(await (await call(`/devices/${device}`, "PUT", registration())).json()).toMatchObject({ status: "stale" });
  expect(await (await call(`/devices/${device}`, "PUT", registration(2))).json()).toMatchObject({ status: "revoked" });
  expect(await (await call("/events", "POST", event())).json()).toMatchObject({ status: "revoked" });
  expect(send).not.toHaveBeenCalled();
  await call(`/devices/${device}`, "PUT", registration(3));
  const next = event({ event_id: "33".repeat(32), targets: [{ device_id: device, generation: 3, sealed: btoa("y".repeat(80)) }] });
  expect(await (await call("/events", "POST", next)).json()).toMatchObject({ status: "accepted" });
  expect(send).toHaveBeenCalledTimes(1);
});

test("a removal waits for in-flight egress and later events cannot start new sends", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  let release!: () => void;
  const finish = new Promise<void>(resolve => { release = resolve; });
  const send = vi.fn(async () => { entered(); await finish; return new Response(null, { status: 200 }); });
  vi.stubGlobal("fetch", send);
  const sending = call("/events", "POST", event());
  await started;
  let removed = false;
  const removal = call(`/devices/${device}/revoke`, "POST", { v: 1, generation: 2 }).then(response => { removed = true; return response; });
  await new Promise(resolve => setTimeout(resolve, 10));
  expect(removed).toBe(false);
  release();
  expect((await sending).status).toBe(200);
  expect((await removal).status).toBe(200);
  expect(await (await call("/events", "POST", event({ event_id: "44".repeat(32) }))).json()).toMatchObject({ status: "revoked" });
  expect(send).toHaveBeenCalledTimes(1);
});

test("presence suppresses only the visible chat and stale revisions cannot restore a cleared lease", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  const visible = { v: 1, generation: 1, revision: 1, visible_chat: "22".repeat(32), visible_until: Math.floor(Date.now() / 1000) + 60 };
  expect(await (await call(`/devices/${device}/presence`, "POST", visible)).json()).toMatchObject({ status: "accepted" });
  expect(await (await call("/events", "POST", event())).json()).toMatchObject({ status: "suppressed" });
  expect(await (await call(`/devices/${device}/presence`, "POST", { ...visible, revision: 2, visible_chat: null, visible_until: 0 })).json()).toMatchObject({ status: "accepted" });
  expect(await (await call(`/devices/${device}/presence`, "POST", visible)).json()).toMatchObject({ status: "stale" });
  expect(await (await call("/events", "POST", event({ event_id: "44".repeat(32) }))).json()).toMatchObject({ status: "accepted" });
  expect(send).toHaveBeenCalledTimes(1);
});

test("cancellation arriving before the request event is durable and prevents egress", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  const requestID = "55".repeat(32), now = Math.floor(Date.now() / 1000);
  await call("/cancellations", "POST", { v: 1, request_id: requestID, expires_at: now + 300 });
  await evictDurableObject(env.INSTALLATIONS.getByName(await installID()));
  expect(await (await call("/events", "POST", event({ kind: "approval", request_id: requestID, expires_at: now + 300 }))).json()).toMatchObject({ status: "cancelled" });
  expect(send).not.toHaveBeenCalled();
});

test("known temporary rejection retries from a durable alarm while ambiguous outcomes do not replay", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  let attempts = 0;
  const send = vi.fn(async () => ++attempts === 1
    ? Response.json({ reason: "ServiceUnavailable" }, { status: 503 })
    : new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  const submitted = event();
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ status: "queued" });
  const stub = env.INSTALLATIONS.getByName(await installID());
  await new Promise(resolve => setTimeout(resolve, 5100));
  expect(await runDurableObjectAlarm(stub)).toBe(true);
  expect(send).toHaveBeenCalledTimes(2);
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ status: "duplicate" });
  expect(send).toHaveBeenCalledTimes(2);

  send.mockRejectedValueOnce(new Error("connection_lost"));
  const ambiguous = event({ event_id: "66".repeat(32) });
  expect(await (await call("/events", "POST", ambiguous)).json()).toMatchObject({ status: "unknown" });
  expect(await (await call("/events", "POST", ambiguous)).json()).toMatchObject({ status: "duplicate" });
  expect(send).toHaveBeenCalledTimes(3);
}, 40_000);

test("invalid targets are retired and never substituted with a later token generation", async () => {
  const send = vi.fn(async () => Response.json({ reason: "Unregistered" }, { status: 410 }));
  vi.stubGlobal("fetch", send);
  await call(`/devices/${device}`, "PUT", registration());
  const submitted = event();
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ status: "invalid_target" });
  expect(await (await call(`/devices/${device}`, "PUT", registration())).json()).toMatchObject({ status: "revoked" });
  expect(await (await call("/events", "POST", event({ event_id: "77".repeat(32) }))).json()).toMatchObject({ status: "revoked" });
  await call(`/devices/${device}`, "PUT", registration(2));
  expect(await (await call("/events", "POST", submitted)).json()).toMatchObject({ status: "duplicate" });
  expect(send).toHaveBeenCalledTimes(1);
});

test("per-device preferences retain routing ciphertext and isolate sandbox from production", async () => {
  const other = "02".repeat(16);
  await call(`/devices/${device}`, "PUT", { ...registration(), preferences: { replies: false, requests: true, failures: true, previews: false } });
  await call(`/devices/${other}`, "PUT", { ...registration(), environment: "production", token: "ef".repeat(32) });
  const requests: { url: string; init: RequestInit }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit) => { requests.push({ url, init }); return new Response(null, { status: 200 }); }));
  const submitted = event({ targets: [
    { device_id: device, generation: 1, sealed: btoa("x".repeat(80)) },
    { device_id: other, generation: 1, sealed: btoa("y".repeat(80)) },
  ] });
  const result = await (await call("/events", "POST", submitted)).json<{ targets: { device_id: string; status: string }[] }>();
  expect(result.targets).toEqual([{ device_id: device, status: "suppressed" }, { device_id: other, status: "accepted" }]);
  expect(requests).toHaveLength(1);
  expect(requests[0]!.url).toBe(`https://api.push.apple.com/3/device/${"ef".repeat(32)}`);
  expect(JSON.parse(requests[0]!.init.body as string).botto.sealed).toBe(btoa("y".repeat(80)));
  const now = Math.floor(Date.now() / 1000);
  await call("/events", "POST", event({ event_id: "88".repeat(32), kind: "approval", request_id: "99".repeat(32), expires_at: now + 300 }));
  expect(requests).toHaveLength(2);
  expect(JSON.parse(requests[1]!.init.body as string).botto.sealed).toBe(btoa("x".repeat(80)));
});

test("expiry, unsupported targets, plaintext fields, and invalid envelopes fail without egress", async () => {
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  expect((await call(`/devices/${device}`, "PUT", { ...registration(), bundle_id: "com.example.unapproved" })).status).toBe(400);
  expect((await call(`/devices/${device}`, "PUT", { ...registration(), environment: "unknown" })).status).toBe(400);
  expect((await call(`/devices/${device}`, "PUT", { ...registration(), preview_key: "never-accepted" })).status).toBe(400);
  await call(`/devices/${device}`, "PUT", registration());
  const now = Math.floor(Date.now() / 1000);
  expect(await (await call("/events", "POST", event({ created_at: now - 4000, expires_at: now - 400 }))).json()).toMatchObject({ status: "expired" });
  expect((await call("/events", "POST", { ...event(), title: "private plaintext" })).status).toBe(400);
  expect((await call("/events", "POST", event({ targets: [{ device_id: device, generation: 1, sealed: "not base64" }] }))).status).toBe(400);
  expect((await call("/events", "POST", event({ targets: [{ device_id: device, generation: 1, sealed: btoa("x".repeat(2800)) }] }))).status).toBe(413);
  expect((await call("/events", "POST", event({ expires_at: now + 3601 }))).status).toBe(400);
  expect(send).not.toHaveBeenCalled();
});

test("presence leases expire, preserve generation, and reject stale or conflicting updates", async () => {
  const now = Math.floor(Date.now() / 1000);
  await call(`/devices/${device}`, "PUT", registration());
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  const presence = { v: 1, generation: 1, revision: 1, visible_chat: "22".repeat(32), visible_until: now + 1000 };
  expect(await (await call(`/devices/${device}/presence`, "POST", presence)).json()).toMatchObject({ status: "accepted" });
  expect(await (await call(`/devices/${device}/presence`, "POST", presence)).json()).toMatchObject({ status: "duplicate" });
  expect((await call(`/devices/${device}/presence`, "POST", { ...presence, visible_chat: null })).status).toBe(409);
  expect(await (await call(`/devices/${device}/presence`, "POST", { ...presence, generation: 2, revision: 2 })).json()).toMatchObject({ status: "stale" });
  const realNow = Date.now;
  vi.spyOn(Date, "now").mockImplementation(() => realNow() + 91_000);
  expect(await (await call("/events", "POST", event())).json()).toMatchObject({ status: "accepted" });
  expect(send).toHaveBeenCalledTimes(1);
});

test("an event ID cannot be reused with different ciphertext", async () => {
  await call(`/devices/${device}`, "PUT", registration());
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  const submitted = event();
  await call("/events", "POST", submitted);
  expect((await call("/events", "POST", { ...submitted, targets: [{ device_id: device, generation: 1, sealed: btoa("y".repeat(80)) }] })).status).toBe(409);
  expect(send).toHaveBeenCalledTimes(1);
});

test("registration and body limits reject excess work before any provider request", async () => {
  const send = vi.fn(async () => new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", send);
  for (let index = 0; index < 32; index++) {
    const id = index.toString(16).padStart(32, "0");
    expect((await call(`/devices/${id}`, "PUT", registration())).status).toBe(200);
  }
  const over = await call(`/devices/${"ff".repeat(16)}`, "PUT", registration());
  expect(over.status).toBe(429);
  expect(await over.json()).toMatchObject({ status: "device_limit" });
  const body = await call("/events", "POST", { v: 1, padding: "x".repeat(32768) });
  expect(body.status).toBe(413);
  expect(send).not.toHaveBeenCalled();
});
