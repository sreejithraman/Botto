import production from '../../.artifacts/deploy/worker.js';
export { Installation } from '../../.artifacts/deploy/worker.js';

// Test-only replacement of the public provider transport, matching the relay's
// existing external-fetch test seam. No production fields or methods change.
const providerFetch = globalThis.fetch.bind(globalThis);
globalThis.fetch = async (input, init) => {
  const result = await providerFetch(input, init);
  const url = typeof input === 'string' ? input : input.url;
  if (url.startsWith('https://api.sandbox.push.apple.com/3/device/') && result.status === 200) {
    await result.body?.cancel();
    return new Response(new ReadableStream({
      cancel() {
        // APNsSender awaits its response body's cancellation before returning
        // accepted. Keep this promise inside workerd, rather than crossing the
        // Node fetcher bridge that could buffer or decouple stream cancellation.
        return providerFetch('https://botto-crash-checkpoint.invalid/after-provider-200-before-receipt', {
          method: 'POST', body: 'synthetic-provider-response-checkpoint',
        }).then(async checkpoint => { await checkpoint.body?.cancel(); });
      },
    }), { status: 200 });
  }
  return result;
};
export default production;
