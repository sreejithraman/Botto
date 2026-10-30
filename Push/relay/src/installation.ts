import { DurableObject } from "cloudflare:workers";
import type { RelayEnv } from "./env";
import { APNsSender, payload, type NotificationSender } from "./apns";
import { suppression } from "./policy";
import { parseCommand, reject, RelayError, response, type PushEvent, type Registration, type Target } from "./protocol";

interface Device {
  generation: number; registration: Registration | null;
  visibleChat: string | null; visibleUntil: number; presenceRevision: number;
  presenceRequest?: { visible_chat: string | null; visible_until: number };
}
type ReceiptStatus = "sending" | "queued" | "accepted" | "suppressed" | "expired" | "revoked" | "cancelled" | "unknown" | "invalid_target" | "permanent_failure";
interface Receipt {
  installationID: string; event: PushEvent; target: Target; fingerprint: string;
  status: ReceiptStatus; attempts: number; nextAttempt: number; retainUntil: number;
}
interface Budget { hour: number; registrations: number; events: number }

export class Installation extends DurableObject<RelayEnv> {
  private tail: Promise<unknown> = Promise.resolve();
  private readonly sender: NotificationSender;

  constructor(ctx: DurableObjectState, env: RelayEnv) {
    super(ctx, env);
    this.sender = new APNsSender(env);
  }

  fetch(request: Request): Promise<Response> {
    const operation = this.tail.then(() => this.handle(request));
    this.tail = operation.catch(() => undefined);
    return operation;
  }

  private async handle(request: Request): Promise<Response> {
    try {
      const command = await parseCommand(request);
      const now = Math.floor(Date.now() / 1000);
      await this.clean(now);
      await this.budget(command.kind === "event" ? "events" : "registrations", now);
      if (command.kind === "register") {
        const r = command.value;
        if (!this.env.ALLOWED_BUNDLE_IDS.split(",").map(x => x.trim()).includes(r.bundle_id)
          || !this.env.ALLOWED_ENVIRONMENTS.split(",").map(x => x.trim()).includes(r.environment)) reject(400, "unsupported_target");
        const key = `device:${command.deviceID}`;
        const old = await this.ctx.storage.get<Device>(key);
        if (old && old.generation > r.generation) return response("stale");
        if (old?.generation === r.generation) {
          if (old.registration === null) return response("revoked");
          if (JSON.stringify(old.registration) !== JSON.stringify(r)) reject(409, "generation_conflict");
          return response("duplicate");
        }
        const records = await this.ctx.storage.list<Device>({ prefix: "device:" });
        if (!old && records.size >= 128 || [...records.values()].filter(d => d.registration !== null).length >= 32 && !old?.registration) reject(429, "device_limit");
        await this.ctx.storage.put(key, { generation: r.generation, registration: r,
          visibleChat: r.visible_chat, visibleUntil: Math.min(r.visible_until, now + 90), presenceRevision: 0 } satisfies Device);
        return response("accepted");
      }
      if (command.kind === "presence") {
        const key = `device:${command.deviceID}`;
        const old = await this.ctx.storage.get<Device>(key);
        if (!old?.registration) return response("revoked");
        const p = command.value;
        if (old.generation !== p.generation || old.presenceRevision > p.revision) return response("stale");
        const request = { visible_chat: p.visible_chat, visible_until: p.visible_until };
        if (old.presenceRevision === p.revision) {
          if (JSON.stringify(old.presenceRequest) !== JSON.stringify(request)) reject(409, "presence_conflict");
          return response("duplicate");
        }
        await this.ctx.storage.put(key, { ...old, visibleChat: p.visible_chat, visibleUntil: Math.min(p.visible_until, now + 90),
          presenceRevision: p.revision, presenceRequest: request } satisfies Device);
        return response("accepted");
      }
      if (command.kind === "revoke") {
        const key = `device:${command.deviceID}`;
        const old = await this.ctx.storage.get<Device>(key);
        if (old && old.generation > command.generation) return response("stale");
        if (old?.generation === command.generation && old.registration !== null) reject(409, "generation_conflict");
        if (!old && (await this.ctx.storage.list({ prefix: "device:" })).size >= 128) reject(429, "device_limit");
        await this.ctx.storage.put(key, { generation: command.generation, registration: null, visibleChat: null, visibleUntil: 0, presenceRevision: 0 } satisfies Device);
        const receipts = await this.ctx.storage.list<Receipt>({ prefix: "receipt:" });
        for (const [receiptKey, receipt] of receipts) {
          if (receipt.target.device_id === command.deviceID && receipt.target.generation <= command.generation && receipt.status === "queued") {
            await this.ctx.storage.put(receiptKey, { ...receipt, status: "revoked", nextAttempt: 0 } satisfies Receipt);
          }
        }
        await this.schedule(now);
        return response(old?.generation === command.generation ? "duplicate" : "accepted");
      }
      if (command.kind === "cancel") {
        const c = command.value;
        if (c.expires_at <= now) return response("expired");
        const key = `cancel:${c.request_id}`;
        const previous = await this.ctx.storage.get<number>(key);
        if (!previous && (await this.ctx.storage.list({ prefix: "cancel:" })).size >= 512) reject(429, "cancellation_limit");
        await this.ctx.storage.put(key, Math.max(previous ?? 0, c.expires_at));
        const receipts = await this.ctx.storage.list<Receipt>({ prefix: "receipt:" });
        for (const [receiptKey, receipt] of receipts) {
          if (receipt.event.request_id === c.request_id && receipt.status === "queued") {
            await this.ctx.storage.put(receiptKey, { ...receipt, status: "cancelled", nextAttempt: 0 } satisfies Receipt);
          }
        }
        await this.schedule(now);
        return response(previous && previous >= c.expires_at ? "duplicate" : "accepted");
      }
      const event = command.value;
      if (event.expires_at <= now) return response("expired");
      const installationID = new URL(request.url).pathname.split("/")[3]!;
      if (event.targets.some(target => new TextEncoder().encode(payload(installationID, event, target)).byteLength > 4096)) reject(413, "payload_too_large");
      const existing = await this.ctx.storage.list<Receipt>({ prefix: "receipt:" });
      if (existing.size + event.targets.filter(target => !existing.has(this.receiptKey(event, target))).length > 512) reject(429, "receipt_limit");
      const results: { device_id: string; status: string }[] = [];
      // Validate every duplicate before sending any target, avoiding partial sends on a conflict.
      for (const target of event.targets) {
        const previous = existing.get(this.receiptKey(event, target));
        if (previous && previous.fingerprint !== await this.fingerprint(event, target)) reject(409, "event_conflict");
      }
      for (const target of event.targets) {
        const key = this.receiptKey(event, target);
        if (existing.has(key)) { results.push({ device_id: target.device_id, status: "duplicate" }); continue; }
        const receipt: Receipt = { installationID, event: { ...event, targets: [target] }, target,
          fingerprint: await this.fingerprint(event, target), status: "queued", attempts: 0, nextAttempt: now,
          retainUntil: event.expires_at + 600 };
        await this.saveReceipt(key, receipt);
        results.push({ device_id: target.device_id, status: await this.deliver(key, receipt) });
      }
      await this.schedule(Math.floor(Date.now() / 1000));
      const statuses = new Set(results.map(r => r.status));
      return response(statuses.size === 1 ? results[0]!.status : "accepted", 200, { targets: results });
    } catch (error) {
      return error instanceof RelayError ? response(error.status, error.code) : response("unavailable", 503);
    }
  }

  alarm(): Promise<void> {
    const operation = this.tail.then(async () => {
      const now = Math.floor(Date.now() / 1000);
      await this.clean(now);
      const receipts = await this.ctx.storage.list<Receipt>({ prefix: "receipt:" });
      for (const [key, receipt] of receipts) {
        if (receipt.status === "queued" && receipt.nextAttempt <= Math.floor(Date.now() / 1000)) await this.deliver(key, receipt);
      }
      await this.schedule(Math.floor(Date.now() / 1000));
    });
    this.tail = operation.catch(() => undefined);
    return operation;
  }

  private receiptKey(event: PushEvent, target: Target): string { return `receipt:${event.event_id}:${target.device_id}:${target.generation}`; }
  private async fingerprint(event: PushEvent, target: Target): Promise<string> {
    const value = JSON.stringify([event.event_id, event.thread_id, event.kind, event.request_id, event.created_at, event.expires_at, target.device_id, target.generation, target.sealed]);
    return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)))].map(b => b.toString(16).padStart(2, "0")).join("");
  }
  private async deliver(key: string, receipt: Receipt): Promise<ReceiptStatus> {
    const device = await this.ctx.storage.get<Device>(`device:${receipt.target.device_id}`);
    let status: ReceiptStatus;
    const cancellationExpiry = receipt.event.request_id === null ? 0 : await this.ctx.storage.get<number>(`cancel:${receipt.event.request_id}`) ?? 0;
    const now = Math.floor(Date.now() / 1000);
    let retryAt = 0;
    if (!device?.registration || device.generation !== receipt.target.generation) status = "revoked";
    else {
      const skipped = suppression(device.registration, receipt.event, device.visibleChat, device.visibleUntil, cancellationExpiry, now);
      if (skipped) status = skipped;
      else {
        // Persist the reservation before egress. A restarted unresolved reservation
        // becomes unknown, not an automatic replay of a possibly accepted push.
        receipt = { ...receipt, status: "sending", attempts: receipt.attempts + 1, nextAttempt: 0 };
        await this.saveReceipt(key, receipt);
        const sent = await this.sender.send(receipt.installationID, device.registration, receipt.event, receipt.target);
        const finishedAt = Math.floor(Date.now() / 1000);
        if (sent.status === "invalid_target") {
          await this.ctx.storage.put(`device:${receipt.target.device_id}`, { generation: device.generation,
            registration: null, visibleChat: null, visibleUntil: 0, presenceRevision: 0 } satisfies Device);
          status = "invalid_target";
        } else if (sent.status === "retryable_failure" || sent.status === "configuration_error") {
          retryAt = finishedAt + 5 * 3 ** (receipt.attempts - 1);
          status = finishedAt >= receipt.event.expires_at ? "expired"
            : receipt.attempts < 4 && retryAt < receipt.event.expires_at ? "queued" : "permanent_failure";
        } else status = sent.status;
      }
    }
    const updated: Receipt = { ...receipt, status, nextAttempt: status === "queued" ? retryAt : 0 };
    await this.saveReceipt(key, updated);
    return status;
  }
  private async saveReceipt(key: string, receipt: Receipt): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    const due = receipt.status === "sending" ? now + 1 : receipt.status === "queued"
      ? Math.min(receipt.nextAttempt, receipt.event.expires_at) : receipt.retainUntil;
    // Persisted work and its wakeup must survive the same crash boundary.
    await this.ctx.storage.transaction(async transaction => {
      await transaction.put(key, receipt);
      const existing = await transaction.getAlarm();
      const wake = Math.max(now + 1, due) * 1000;
      if (existing === null || existing > wake) await transaction.setAlarm(wake);
    });
  }
  private async budget(kind: "registrations" | "events", now: number): Promise<void> {
    const hour = Math.floor(now / 3600);
    const previous = await this.ctx.storage.get<Budget>("budget");
    const budget = previous?.hour === hour ? previous : { hour, registrations: 0, events: 0 };
    if (budget[kind] >= (kind === "events" ? 600 : 4096)) reject(429, "installation_limit");
    budget[kind]++;
    await this.ctx.storage.put("budget", budget);
  }
  private async clean(now: number): Promise<void> {
    const receipts = await this.ctx.storage.list<Receipt>({ prefix: "receipt:" });
    for (const [key, receipt] of receipts) {
      if (receipt.retainUntil <= now) await this.ctx.storage.delete(key);
      else if (receipt.status === "sending") await this.ctx.storage.put(key, { ...receipt, status: "unknown", nextAttempt: 0 } satisfies Receipt);
    }
    for (const [key, expiry] of await this.ctx.storage.list<number>({ prefix: "cancel:" })) if (expiry <= now) await this.ctx.storage.delete(key);
  }
  private async schedule(now: number): Promise<void> {
    let earliest = Number.POSITIVE_INFINITY;
    for (const receipt of (await this.ctx.storage.list<Receipt>({ prefix: "receipt:" })).values()) {
      earliest = Math.min(earliest, receipt.retainUntil, ...(receipt.status === "queued" ? [receipt.nextAttempt, receipt.event.expires_at] : []));
    }
    for (const expiry of (await this.ctx.storage.list<number>({ prefix: "cancel:" })).values()) earliest = Math.min(earliest, expiry);
    if (Number.isFinite(earliest)) await this.ctx.storage.setAlarm(Math.max(now + 1, earliest) * 1000);
    else await this.ctx.storage.deleteAlarm();
  }
}
