import type { PushEvent, Registration } from "./protocol";

export type Suppression = "expired" | "suppressed" | "cancelled" | null;
export function suppression(registration: Registration, event: PushEvent, visibleChat: string | null,
  visibleUntil: number, cancellationExpiry: number, now: number): Suppression {
  if (event.expires_at <= now) return "expired";
  if (event.request_id !== null && cancellationExpiry > now) return "cancelled";
  const p = registration.preferences;
  const allowed = event.kind === "reply" ? p.replies : event.kind === "failure" ? p.failures : p.requests;
  if (!allowed || visibleChat === event.thread_id && visibleUntil > now) return "suppressed";
  return null;
}
