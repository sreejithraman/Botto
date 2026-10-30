// Runs only in WKContentWorld's isolated main-frame world. Nothing from the
// child is evaluated here. Child messages are untrusted size/liveness hints.
(() => {
  'use strict';
  const generation = __BOTTO_GENERATION__;
  const send = (kind, height = 120) =>
    window.webkit.messageHandlers.richContent.postMessage({generation, kind, height});
  const frame = document.createElement('iframe');
  frame.title = 'Isolated reply preview';
  frame.sandbox = 'allow-scripts';
  frame.referrerPolicy = 'no-referrer';
  frame.allow = "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; display-capture 'none'; fullscreen 'none'; payment 'none'; usb 'none'; serial 'none'; bluetooth 'none'; accelerometer 'none'; gyroscope 'none'; magnetometer 'none'; autoplay 'none'";
  let height = 120;
  let lastChild = performance.now();
  let ready = false;
  let failed = false;
  window.addEventListener('message', event => {
    if (event.source !== frame.contentWindow || event.origin !== 'null') return;
    const data = event.data;
    if (!data || typeof data !== 'object' || data.channel !== 'botto-size') return;
    if (data.kind === 'failed') { failed = true; return; }
    if (data.kind !== 'ready' && data.kind !== 'alive') return;
    lastChild = performance.now();
    if (data.kind === 'ready') ready = true;
    if (typeof data.height === 'number' && Number.isFinite(data.height) && data.height > 0) {
      height = Math.max(height, Math.min(480, Math.ceil(data.height)));
    }
  });
  // Emit at most twice per second, regardless of a hostile postMessage flood.
  setInterval(() => {
    if (failed) { send('failed'); return; }
    if (!ready || performance.now() - lastChild > 1500) return;
    send('ready', height);
  }, 500);
  frame.srcdoc = __BOTTO_DOCUMENT__;
  document.body.append(frame);
})();
