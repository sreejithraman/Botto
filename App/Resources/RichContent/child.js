// This script shares the child's untrusted realm. Its reports are only hints;
// all limits and bridge authorization live in the host and native renderer.
(() => {
  let ready = false;
  const report = () => {
    if (window.bottoPreviewFailed) {
      parent.postMessage({channel:'botto-size', kind:'failed'}, '*');
      return;
    }
    if (window.bottoPreviewPending) return;
    const height = Math.max(document.body?.scrollHeight || 0,
      document.body?.getBoundingClientRect().height || 0) + 24;
    parent.postMessage({channel:'botto-size', kind:ready ? 'alive' : 'ready', height}, '*');
    ready = true;
  };
  report();
  setInterval(report, 500);
})();
