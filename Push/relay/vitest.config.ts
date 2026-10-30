import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
const exported = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer);
const privateKey = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...exported))}\n-----END PRIVATE KEY-----`;

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: { bindings: { APNS_TEAM_ID: "TESTTEAM01", APNS_KEY_ID: "TESTKEY001", APNS_PRIVATE_KEY: privateKey } },
  })],
  test: { testTimeout: 15_000 },
});
