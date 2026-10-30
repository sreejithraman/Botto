import { exports } from "cloudflare:workers";
import { afterEach, expect, test, vi } from "vitest";
import fixture from "../../fixtures/payload-boundary.json";

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

test("a legal encrypted preview above3500 characters reaches the provider within its complete payload budget", async () => {
  const envelope = fixture.envelope;
  const call = (suffix: string, method: string, body: unknown) => exports.default.fetch(
    `https://relay.test/v1/installations/${envelope.installation_id}${suffix}`, {
      method, headers: { Authorization: `Bearer ${"ab".repeat(32)}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  expect((await call(`/devices/${envelope.device_id}`, "PUT", {
    v: 1, generation: 1, token: "cd".repeat(32), bundle_id: "com.sree.botto", environment: "sandbox",
    preferences: { replies: true, requests: true, failures: true, previews: true }, visible_chat: null, visible_until: 0,
  })).status).toBe(200);
  const now = Math.floor(Date.now() / 1000);
  const send = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
    const body = String(init?.body);
    expect(new TextEncoder().encode(body).byteLength).toBe(fixture.expected.apns_bytes);
    expect(JSON.parse(body)).toEqual({
      aps: { alert: { title: "Botto", body: "New activity" }, "mutable-content": 1, "thread-id": "4".repeat(64), sound: "default" },
      botto: { ...envelope, expires_at: now + 3600 },
    });
    return new Response(null, { status: 200 });
  });
  vi.stubGlobal("fetch", send);
  const event = { v: 1, event_id: envelope.event_id, thread_id: "4".repeat(64), kind: "reply", request_id: null,
    created_at: now, expires_at: now + 3600,
    targets: [{ device_id: envelope.device_id, generation: 1, sealed: envelope.sealed }] };
  const result = await call("/events", "POST", event);
  expect(result.status).toBe(200);
  expect(await result.json()).toMatchObject({ status: "accepted" });
  expect(send).toHaveBeenCalledTimes(1);
  const oversized = await call("/events", "POST", {
    ...event, event_id: "5".repeat(64), targets: [{ ...event.targets[0], sealed: btoa("x".repeat(2800)) }],
  });
  expect(oversized.status).toBe(413);
  expect(await oversized.json()).toMatchObject({ status: "payload_too_large" });
  expect(send).toHaveBeenCalledTimes(1);
});
