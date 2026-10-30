import type { RelayEnv } from "./env";
import type { PushEvent, Registration, Target } from "./protocol";

export type DeliveryStatus = "accepted" | "expired" | "invalid_target" | "retryable_failure" | "permanent_failure" | "unknown" | "configuration_error";
export interface DeliveryResult { status: DeliveryStatus }
export interface NotificationSender {
  send(installationID: string, registration: Registration, event: PushEvent, target: Target): Promise<DeliveryResult>;
}

export function payload(installationID: string, event: PushEvent, target: Target): string {
  return JSON.stringify({
    aps: { alert: { title: "Botto", body: "New activity" }, "mutable-content": 1, "thread-id": event.thread_id, sound: "default" },
    botto: { v: 1, installation_id: installationID, device_id: target.device_id, generation: target.generation,
      event_id: event.event_id, kind: event.kind, expires_at: event.expires_at, sealed: target.sealed },
  });
}
const urlBase64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
const encodedJSON = (value: unknown): string => urlBase64(new TextEncoder().encode(JSON.stringify(value)));

export class APNsSender implements NotificationSender {
  private cached: { token: string; issued: number } | undefined;
  private signingKey: CryptoKey | undefined;
  constructor(private readonly env: RelayEnv) {}

  private async authorization(now: number): Promise<string> {
    if (this.cached && now - this.cached.issued < 1200 && now >= this.cached.issued) return this.cached.token;
    if (!this.env.APNS_TEAM_ID || !this.env.APNS_KEY_ID || !this.env.APNS_PRIVATE_KEY) throw new Error("missing_provider_configuration");
    if (!this.signingKey) {
      const base64 = this.env.APNS_PRIVATE_KEY.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
      const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
      this.signingKey = await crypto.subtle.importKey("pkcs8", bytes, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    }
    const unsigned = `${encodedJSON({ alg: "ES256", kid: this.env.APNS_KEY_ID })}.${encodedJSON({ iss: this.env.APNS_TEAM_ID, iat: now })}`;
    const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.signingKey, new TextEncoder().encode(unsigned)));
    const token = `${unsigned}.${urlBase64(signature)}`;
    this.cached = { token, issued: now };
    return token;
  }

  async send(installationID: string, registration: Registration, event: PushEvent, target: Target): Promise<DeliveryResult> {
    let authorization: string;
    try { authorization = await this.authorization(Math.floor(Date.now() / 1000)); }
    catch { return { status: "configuration_error" }; }
    if (event.expires_at <= Math.floor(Date.now() / 1000)) return { status: "expired" };
    const origin = registration.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    try {
      const result = await fetch(`${origin}/3/device/${registration.token}`, {
        method: "POST", redirect: "manual", signal: AbortSignal.timeout(10_000),
        headers: { authorization: `bearer ${authorization}`, "content-type": "application/json", "apns-topic": registration.bundle_id,
          "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": String(event.expires_at), "apns-collapse-id": event.event_id },
        body: payload(installationID, event, target),
      });
      if (result.status === 200) { await result.body?.cancel(); return { status: "accepted" }; }
      // Status is sufficient; never retain an unbounded provider response or log tokens.
      if (result.status === 410) { await result.body?.cancel(); return { status: "invalid_target" }; }
      let reason: unknown;
      try { reason = (await result.json<{ reason?: unknown }>()).reason; } catch { /* A malformed rejection remains a rejection. */ }
      if (result.status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(String(reason))) return { status: "invalid_target" };
      if (result.status === 429 || result.status >= 500) return { status: "retryable_failure" };
      if (result.status === 403) { this.cached = undefined; return { status: "configuration_error" }; }
      return { status: "permanent_failure" };
    } catch {
      // A connection failure can happen after APNs accepted the request. Blind replay
      // would turn a timeout into an unbounded duplicate-delivery promise.
      return { status: "unknown" };
    }
  }
}
