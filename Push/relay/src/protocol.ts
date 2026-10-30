export type EventKind = "reply" | "approval" | "question" | "failure";
export interface Preferences { replies: boolean; requests: boolean; failures: boolean; previews: boolean }
export interface Registration {
  v: 1; generation: number; token: string; bundle_id: string;
  environment: "sandbox" | "production"; preferences: Preferences;
  visible_chat: string | null; visible_until: number;
}
export interface Target { device_id: string; generation: number; sealed: string }
export interface PushEvent {
  v: 1; event_id: string; thread_id: string; kind: EventKind;
  request_id: string | null; created_at: number; expires_at: number; targets: Target[];
}
export interface Cancellation { v: 1; request_id: string; expires_at: number }
export interface Presence { v: 1; generation: number; revision: number; visible_chat: string | null; visible_until: number }
export type Command =
  | { kind: "register"; deviceID: string; value: Registration }
  | { kind: "revoke"; deviceID: string; generation: number }
  | { kind: "presence"; deviceID: string; value: Presence }
  | { kind: "event"; value: PushEvent }
  | { kind: "cancel"; value: Cancellation };

export class RelayError extends Error {
  constructor(readonly code: number, readonly status: string) { super(status); }
}
export function response(status: string, code = 200, fields: Record<string, unknown> = {}): Response {
  return Response.json({ v: 1, status, ...fields }, { status: code, headers: { "Cache-Control": "no-store" } });
}
export function reject(code = 400, status = "invalid_request"): never { throw new RelayError(code, status); }
export const hex = (value: unknown, length: number): value is string => typeof value === "string" && new RegExp(`^[0-9a-f]{${length}}$`).test(value);
const integer = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;
const generation = (value: unknown): value is number => integer(value) && value > 0;
function object(value: unknown, keys: string[]): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) reject();
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some(key => !keys.includes(key)) || keys.some(key => !(key in record))) reject();
  return record;
}
function preferences(value: unknown): Preferences {
  const record = object(value, ["replies", "requests", "failures", "previews"]);
  if (Object.values(record).some(value => typeof value !== "boolean")) reject();
  return { replies: record.replies as boolean, requests: record.requests as boolean, failures: record.failures as boolean, previews: record.previews as boolean };
}
function registration(value: unknown): Registration {
  const r = object(value, ["v", "generation", "token", "bundle_id", "environment", "preferences", "visible_chat", "visible_until"]);
  if (r.v !== 1 || !generation(r.generation) || typeof r.token !== "string" || !/^(?:[0-9a-f]{2}){16,256}$/.test(r.token)
    || typeof r.bundle_id !== "string" || r.bundle_id.length > 200 || !/^[A-Za-z0-9][A-Za-z0-9.-]+$/.test(r.bundle_id)
    || !["sandbox", "production"].includes(r.environment as string) || !(r.visible_chat === null || hex(r.visible_chat, 64))
    || !integer(r.visible_until)) reject();
  return { v: 1, generation: r.generation, token: r.token, bundle_id: r.bundle_id,
    environment: r.environment as Registration["environment"], preferences: preferences(r.preferences),
    visible_chat: r.visible_chat as string | null, visible_until: r.visible_until };
}
function target(value: unknown): Target {
  const r = object(value, ["device_id", "generation", "sealed"]);
  if (!hex(r.device_id, 32) || !generation(r.generation) || typeof r.sealed !== "string" || r.sealed.length > 4096
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(r.sealed)) reject();
  try { const size = atob(r.sealed).length; if (size < 28 || size > 3072) reject(); } catch { reject(); }
  return r as unknown as Target;
}
function event(value: unknown): PushEvent {
  const r = object(value, ["v", "event_id", "thread_id", "kind", "request_id", "created_at", "expires_at", "targets"]);
  if (r.v !== 1 || !hex(r.event_id, 64) || !hex(r.thread_id, 64)
    || !["reply", "approval", "question", "failure"].includes(r.kind as string)
    || !(r.request_id === null || hex(r.request_id, 64)) || !integer(r.created_at) || !integer(r.expires_at)
    || !Array.isArray(r.targets) || r.targets.length < 1 || r.targets.length > 32) reject();
  const ttl = r.kind === "approval" || r.kind === "question" ? 300 : 3600;
  if (r.expires_at <= r.created_at || r.expires_at - r.created_at > ttl || r.created_at > Math.floor(Date.now() / 1000) + 60) reject();
  const targets = r.targets.map(target);
  if (new Set(targets.map(t => t.device_id)).size !== targets.length) reject();
  return { ...r, targets } as unknown as PushEvent;
}

export async function parseCommand(request: Request): Promise<Command> {
  const path = new URL(request.url).pathname;
  const base = /^\/v1\/installations\/[0-9a-f]{64}/;
  const suffix = path.replace(base, "");
  const device = /^\/devices\/([0-9a-f]{32})(\/(?:revoke|presence))?$/.exec(suffix);
  if (device?.[1]) {
    if (device[2] === "/presence") {
      if (request.method !== "POST") reject(405, "method_not_allowed");
      const r = object(await jsonBody(request), ["v", "generation", "revision", "visible_chat", "visible_until"]);
      if (r.v !== 1 || !generation(r.generation) || !generation(r.revision)
        || !(r.visible_chat === null || hex(r.visible_chat, 64)) || !integer(r.visible_until)) reject();
      return { kind: "presence", deviceID: device[1], value: r as unknown as Presence };
    }
    if (device[2] === "/revoke") {
      if (request.method !== "POST") reject(405, "method_not_allowed");
      const r = object(await jsonBody(request), ["v", "generation"]);
      if (r.v !== 1 || !generation(r.generation)) reject();
      return { kind: "revoke", deviceID: device[1], generation: r.generation };
    }
    if (request.method !== "PUT") reject(405, "method_not_allowed");
    return { kind: "register", deviceID: device[1], value: registration(await jsonBody(request)) };
  }
  if (suffix === "/events") {
    if (request.method !== "POST") reject(405, "method_not_allowed");
    return { kind: "event", value: event(await jsonBody(request)) };
  }
  if (suffix === "/cancellations") {
    if (request.method !== "POST") reject(405, "method_not_allowed");
    const r = object(await jsonBody(request), ["v", "request_id", "expires_at"]);
    if (r.v !== 1 || !hex(r.request_id, 64) || !integer(r.expires_at) || r.expires_at > Math.floor(Date.now() / 1000) + 300) reject();
    return { kind: "cancel", value: r as unknown as Cancellation };
  }
  reject(404, "not_found");
}

export async function jsonBody(request: Request): Promise<unknown> {
  if (request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") reject(415, "json_required");
  if (Number(request.headers.get("content-length")) > 32768) reject(413, "body_too_large");
  const reader = request.body?.getReader();
  if (!reader) reject();
  let length = 0;
  const chunks: Uint8Array[] = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 32768) { await reader.cancel(); reject(413, "body_too_large"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); } catch { reject(); }
}
