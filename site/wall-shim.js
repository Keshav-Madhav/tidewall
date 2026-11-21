// Lets a wall run inside a web page: the embedding page plays Tidewall's part (it says where the "windows" are)
(() => {
  if (window.top === window) return;
  const pd = parseFloat(new URLSearchParams(location.search).get('pdpr'));
  if (pd > 0) try { Object.defineProperty(window, 'devicePixelRatio', { get: () => pd, configurable: true }); } catch (_) {}
  const ls = [];
  window.chrome = window.chrome || {};
  window.chrome.webview = { postMessage: m => parent.postMessage({ __twFrom: typeof m === 'string' ? m : JSON.stringify(m) }, '*'),
    addEventListener: (t, f) => { if (t === 'message') ls.push(f); }, removeEventListener: () => {} };
  addEventListener('message', e => { if (e.source === parent && e.data && e.data.__tw !== undefined) for (const f of ls) f({ data: e.data.__tw }); });
  window.__opaque = true;
})();
