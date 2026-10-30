// Defense in depth for APIs (notably WebRTC) that are not uniformly covered by
// connect-src. Installed at document start in EVERY page-world frame. Sandbox,
// CSP, rule lists and the navigation delegate remain the primary boundaries.
(() => {
  const deny = (object, name) => {
    try { Object.defineProperty(object, name, {value:undefined, writable:false, configurable:false}); }
    catch (_) {}
  };
  for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel',
    'WebTransport', 'WebSocket', 'Worker', 'SharedWorker', 'webkit',
    'Notification', 'PaymentRequest', 'openDatabase', 'showOpenFilePicker',
    'showSaveFilePicker', 'showDirectoryPicker', 'print', 'speechSynthesis',
    'AudioContext', 'webkitAudioContext']) deny(window, name);
  for (const name of ['geolocation', 'mediaDevices', 'clipboard', 'credentials',
    'serviceWorker', 'usb', 'serial', 'bluetooth', 'gpu', 'xr', 'share', 'canShare',
    'vibrate', 'getUserMedia', 'webkitGetUserMedia']) deny(navigator, name);
  deny(HTMLInputElement.prototype, 'showPicker');
  // WKUIDelegate can deny file panels starting in iOS 18.4. Keep iOS 18.0–18.3
  // file inputs inert as well, including label activation and element.click().
  window.addEventListener('click', event => {
    if (event.composedPath().some(node => node instanceof HTMLInputElement && node.type === 'file')) {
      event.preventDefault(); event.stopImmediatePropagation();
    }
  }, true);
})();
