import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { request as httpRequest } from 'node:http';

let runtime;
let config;
let ProviderResponse;
const send = value => process.send?.(value);
const never = () => new Promise(() => {});

function providerRequest(value) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(value);
    const request = httpRequest(config.providerURL, {
      method: 'POST', headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) },
      timeout: 15_000,
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('fixture_provider_timeout')));
    request.on('error', reject);
    request.end(data);
  });
}

async function start(value) {
  config = value;
  const require = createRequire(`${config.relayRoot}/package.json`);
  const { Miniflare, Response, convertV4MiniflareOptions } = require('miniflare');
  ProviderResponse = Response;
  runtime = new Miniflare(convertV4MiniflareOptions({
    name: 'botto-owned-process-crash-proof',
    ...(config.cancelProbe
      ? { modules: [{ type: 'ESModule', path: config.providerEntry }, { type: 'ESModule', path: config.bundle }] }
      : { modules: true, scriptPath: config.bundle }),
    modulesRoot: config.workspace,
    compatibilityDate: '2026-10-29', compatibilityFlags: ['nodejs_compat'],
    resourcePersistencePath: config.persistence, logRequests: false,
    durableObjects: { INSTALLATIONS: { className: 'Installation', useSQLite: true } },
    ratelimits: { REQUEST_LIMITER: { namespace_id: '1001', simple: { limit: 120, period: 60 } } },
    bindings: { ALLOWED_BUNDLE_IDS: 'com.sree.botto', ALLOWED_ENVIRONMENTS: 'sandbox,production',
      APNS_TEAM_ID: 'TESTTEAM01', APNS_KEY_ID: 'TESTKEY001', APNS_PRIVATE_KEY: config.privateKey },
    outboundService: async request => {
      if (request.url === 'https://botto-crash-checkpoint.invalid/after-provider-200-before-receipt') {
        assert(config.cancelProbe, 'checkpoint must be restricted to the explicit provider-wrapper phase');
        assert.equal(request.method, 'POST');
        assert.equal(await request.text(), 'synthetic-provider-response-checkpoint');
        send({ type: 'phase', phase: 'provider_body_cancel_entered' });
        const checkpoint = await providerRequest({ url: request.url, method: request.method, body: null });
        return new ProviderResponse(checkpoint.body || null, { status: checkpoint.status });
      }
      assert.equal(request.url, `https://api.sandbox.push.apple.com/3/device/${config.deviceToken}`);
      assert.equal(request.method, 'POST');
      const body = await request.json();
      const provided = await providerRequest({ url: request.url, method: request.method, body });
      return new ProviderResponse(provided.body || null, { status: provided.status });
    },
  }));
  await runtime.ready;
  send({ type: 'ready', pid: process.pid });
}

process.on('message', async message => {
  try {
    if (message.type === 'start') { await start(message.config); return; }
    if (message.type === 'call') {
      const response = await runtime.dispatchFetch(message.url, {
        method: message.method, headers: message.headers, body: JSON.stringify(message.body),
      });
      const value = { type: 'result', id: message.id, httpStatus: response.status, body: await response.json() };
      if (config.holdEventAck && message.url.endsWith('/events')) {
        send({ type: 'phase', phase: 'public_result_computed_ack_held', observedResult: value });
        await never();
      }
      send(value);
      return;
    }
    if (message.type === 'stop') { await runtime?.dispose(); send({ type: 'stopped' }); process.exit(0); }
  } catch (error) {
    send({ type: 'error', id: message.id ?? null, name: error.name, message: error.message });
  }
});
