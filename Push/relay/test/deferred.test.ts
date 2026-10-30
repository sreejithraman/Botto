import { env, exports } from "cloudflare:workers";
import { runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, expect, test, vi } from "vitest";

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

const device = "01".repeat(16);
const originalToken = "cd".repeat(32);
const replacementToken = "ef".repeat(32);
const sealed = btoa("x".repeat(80));
const replacementSealed = btoa("y".repeat(80));
const eventID = "11".repeat(32);

interface Attempt {
  at: number;
  url: string;
  botto: { device_id: string; generation: number; event_id: string; sealed: string };
}

async function relay() {
  const token = [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, "0")).join("");
  const installation = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)))].map(b => b.toString(16).padStart(2, "0")).join("");
  const call = async (suffix: string, method: string, body: unknown) => {
    const result = await exports.default.fetch(`https://relay.test/v1/installations/${installation}${suffix}`, {
      method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    expect(result.status).toBe(200);
    return result.json<{ v: number; status: string; targets?: { device_id: string; status: string }[] }>();
  };
  const alarm = () => runDurableObjectAlarm(env.INSTALLATIONS.getByName(installation));
  return { call, alarm };
}

function registration(generation = 1, token = originalToken) {
  return { v: 1, generation, token, bundle_id: "com.sree.botto", environment: "sandbox",
    preferences: { replies: true, requests: true, failures: true, previews: true }, visible_chat: null, visible_until: 0 };
}

function event(now: number, overrides: Record<string, unknown> = {}) {
  return { v: 1, event_id: eventID, thread_id: "22".repeat(32), kind: "reply", request_id: null,
    created_at: now, expires_at: now + 3600, targets: [{ device_id: device, generation: 1, sealed }], ...overrides };
}

function provider(reply: (attempt: Attempt, count: number) => Response | Promise<Response>) {
  const attempts: Attempt[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit) => {
    const payload = JSON.parse(init.body as string) as { botto: Attempt["botto"] };
    const attempt = { at: Math.floor(Date.now() / 1000), url, botto: payload.botto };
    attempts.push(attempt);
    return reply(attempt, attempts.length);
  }));
  return attempts;
}

const temporaryRejection = () => Response.json({ reason: "ServiceUnavailable" }, { status: 503 });

test("four rejected attempts exhaust the retry budget without early or later provider sends", async () => {
  const base = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(base * 1000);
  const target = await relay();
  await target.call(`/devices/${device}`, "PUT", registration());
  const attempts = provider(attempt => attempt.botto.event_id === eventID ? temporaryRejection() : new Response(null, { status: 200 }));
  const submitted = event(base);
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "queued" });

  for (const [offset, expected] of [[4, 1], [5, 2], [19, 2], [20, 3], [64, 3], [65, 4], [200, 4], [3000, 4]]) {
    clock.mockReturnValue((base + offset!) * 1000);
    expect(await target.alarm()).toBe(true);
    expect(attempts).toHaveLength(expected!);
  }
  expect(attempts.map(attempt => attempt.at - base)).toEqual([0, 5, 20, 65]);
  expect(attempts.map(attempt => [attempt.url, attempt.botto.event_id, attempt.botto.generation, attempt.botto.sealed])).toEqual(
    [0, 1, 2, 3].map(() => [`https://api.sandbox.push.apple.com/3/device/${originalToken}`, eventID, 1, sealed]),
  );
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "duplicate" });
  expect(attempts).toHaveLength(4);

  // A fresh event still succeeds; the missing fifth retry is not a stalled actor.
  expect(await target.call("/events", "POST", event(base + 3000, { event_id: "33".repeat(32) }))).toMatchObject({ status: "accepted" });
  expect(attempts).toHaveLength(5);
});

test("queued work expires before its overdue retry and a fresh event remains deliverable", async () => {
  const base = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(base * 1000);
  const target = await relay();
  await target.call(`/devices/${device}`, "PUT", registration());
  const attempts = provider((_, count) => count === 1 ? temporaryRejection() : new Response(null, { status: 200 }));
  const submitted = event(base, { expires_at: base + 6 });
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "queued" });
  clock.mockReturnValue((base + 4) * 1000);
  await target.alarm();
  expect(attempts).toHaveLength(1);
  clock.mockReturnValue((base + 6) * 1000);
  await target.alarm();
  clock.mockReturnValue((base + 60) * 1000);
  await target.alarm();
  expect(attempts).toHaveLength(1);
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "expired" });
  expect(await target.call("/events", "POST", event(base + 60, { event_id: "33".repeat(32) }))).toMatchObject({ status: "accepted" });
  expect(attempts.map(attempt => attempt.botto.event_id)).toEqual([eventID, "33".repeat(32)]);
});

test("cancelling an already queued request prevents its retry but permits another request", async () => {
  const base = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(base * 1000);
  const target = await relay();
  await target.call(`/devices/${device}`, "PUT", registration());
  const attempts = provider((_, count) => count === 1 ? temporaryRejection() : new Response(null, { status: 200 }));
  const requestID = "44".repeat(32);
  const submitted = event(base, { kind: "approval", request_id: requestID, expires_at: base + 300 });
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "queued" });
  clock.mockReturnValue((base + 1) * 1000);
  expect(await target.call("/cancellations", "POST", { v: 1, request_id: requestID, expires_at: base + 300 })).toMatchObject({ status: "accepted" });
  for (const offset of [5, 20, 65]) { clock.mockReturnValue((base + offset) * 1000); await target.alarm(); }
  expect(attempts).toHaveLength(1);
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "duplicate" });
  expect(await target.call("/events", "POST", { ...submitted, event_id: "55".repeat(32) })).toMatchObject({ status: "cancelled" });
  expect(attempts).toHaveLength(1);
  expect(await target.call("/events", "POST", { ...submitted, event_id: "66".repeat(32), request_id: "77".repeat(32) })).toMatchObject({ status: "accepted" });
  expect(attempts.map(attempt => attempt.botto.event_id)).toEqual([eventID, "66".repeat(32)]);
});

test("revoking a queued target fences retries and never substitutes a later token generation", async () => {
  const base = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(base * 1000);
  const target = await relay();
  await target.call(`/devices/${device}`, "PUT", registration());
  const attempts = provider((_, count) => count === 1 ? temporaryRejection() : new Response(null, { status: 200 }));
  const submitted = event(base);
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "queued" });
  clock.mockReturnValue((base + 1) * 1000);
  expect(await target.call(`/devices/${device}/revoke`, "POST", { v: 1, generation: 2 })).toMatchObject({ status: "accepted" });
  expect(await target.call(`/devices/${device}`, "PUT", registration(3, replacementToken))).toMatchObject({ status: "accepted" });
  for (const offset of [5, 20, 65]) { clock.mockReturnValue((base + offset) * 1000); await target.alarm(); }
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "duplicate" });
  expect(await target.call("/events", "POST", { ...submitted, event_id: "33".repeat(32) })).toMatchObject({ status: "revoked" });
  expect(attempts).toHaveLength(1);
  expect(await target.call("/events", "POST", event(base + 65, { event_id: "44".repeat(32),
    targets: [{ device_id: device, generation: 3, sealed: replacementSealed }] }))).toMatchObject({ status: "accepted" });
  expect(attempts.map(attempt => [attempt.url, attempt.botto.generation, attempt.botto.sealed])).toEqual([
    [`https://api.sandbox.push.apple.com/3/device/${originalToken}`, 1, sealed],
    [`https://api.sandbox.push.apple.com/3/device/${replacementToken}`, 3, replacementSealed],
  ]);
});

test("replacement during an in-flight attempt retains its original recipient and retires its queued generation", async () => {
  const base = Math.floor(Date.now() / 1000);
  const clock = vi.spyOn(Date, "now").mockReturnValue(base * 1000);
  const target = await relay();
  await target.call(`/devices/${device}`, "PUT", registration());
  let entered!: () => void, release!: () => void;
  const firstEntered = new Promise<void>(resolve => { entered = resolve; });
  const held = new Promise<void>(resolve => { release = resolve; });
  const attempts = provider(async (_, count) => {
    if (count === 1) { entered(); await held; return temporaryRejection(); }
    return new Response(null, { status: 200 });
  });
  const submitted = event(base);
  const sending = target.call("/events", "POST", submitted);
  await firstEntered;
  let replacing: ReturnType<typeof target.call>;
  try {
    expect(attempts[0]).toMatchObject({ url: `https://api.sandbox.push.apple.com/3/device/${originalToken}`,
      botto: { event_id: eventID, generation: 1, sealed } });
    replacing = target.call(`/devices/${device}`, "PUT", registration(2, replacementToken));
    // The replacement is invoked while the provider remains held. Its response
    // ordering is not asserted; recipient and retry-generation behavior are.
    await new Promise(resolve => setTimeout(resolve, 10));
  } finally { release(); }
  expect(await sending).toMatchObject({ status: "queued" });
  expect(await replacing!).toMatchObject({ status: "accepted" });
  clock.mockReturnValue((base + 5) * 1000);
  await target.alarm();
  expect(attempts).toHaveLength(1);
  expect(await target.call("/events", "POST", submitted)).toMatchObject({ status: "duplicate" });
  expect(await target.call("/events", "POST", event(base + 5, { event_id: "33".repeat(32),
    targets: [{ device_id: device, generation: 2, sealed: replacementSealed }] }))).toMatchObject({ status: "accepted" });
  expect(attempts.map(attempt => [attempt.url, attempt.botto.generation, attempt.botto.event_id])).toEqual([
    [`https://api.sandbox.push.apple.com/3/device/${originalToken}`, 1, eventID],
    [`https://api.sandbox.push.apple.com/3/device/${replacementToken}`, 2, "33".repeat(32)],
  ]);
});
