import type { RelayEnv } from "./env";
import { hex, reject, RelayError, response } from "./protocol";
export { Installation } from "./installation";

export default {
  async fetch(request: Request, env: RelayEnv): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) reject(400, "https_required");
      if (request.method === "GET" && url.pathname === "/health" && !url.search) return response("ok");
      const match = /^\/v1\/installations\/([0-9a-f]{64})(?:\/|$)/.exec(url.pathname);
      if (!match?.[1] || url.search) reject(404, "not_found");
      const key = request.headers.get("CF-Connecting-IP") ?? "local";
      if (!(await env.REQUEST_LIMITER.limit({ key })).success) reject(429, "request_limit");
      const credential = /^Bearer ([0-9a-f]{64})$/.exec(request.headers.get("authorization") ?? "")?.[1];
      if (!hex(credential, 64)) reject(401, "unauthorized");
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(credential)));
      const id = [...digest].map(b => b.toString(16).padStart(2, "0")).join("");
      if (id !== match[1]) reject(401, "unauthorized");
      const forwarded = new Request(request);
      forwarded.headers.delete("authorization");
      return await env.INSTALLATIONS.getByName(id).fetch(forwarded);
    } catch (error) {
      return error instanceof RelayError ? response(error.status, error.code) : response("unavailable", 503);
    }
  },
} satisfies ExportedHandler<RelayEnv>;
