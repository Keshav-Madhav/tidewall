// Runs in every frame of the Settings window (as the macOS app's frame shim does). The preview frame is a real wall page:
// it gets the host surface it expects, but its messages go to the page around it, which plays host (a pretend desktop
// with windows you can drag).
(() => {
  if (window.top === window) return;
  // the preview is shown small: render at the pixels it's shown at, not at the full desktop's size
  const pd = parseFloat(new URLSearchParams(location.search).get('pdpr'));
  if (pd > 0) try { Object.defineProperty(window, 'devicePixelRatio', { get: () => pd, configurable: true }); } catch (_) {}
  const ls = [];
  const shim = { postMessage: m => parent.postMessage({ __twFrom: typeof m === 'string' ? m : JSON.stringify(m) }, '*'),
    addEventListener: (t, f) => { if (t === 'message') ls.push(f); }, removeEventListener: () => {} };
  const chrome = window.chrome || (window.chrome = {});
  try { Object.defineProperty(chrome, 'webview', { get: () => shim, configurable: true }); } catch (_) { chrome.webview = shim; }
  addEventListener('message', e => { if (e.source === parent && e.data && e.data.__tw !== undefined) for (const f of ls) f({ data: e.data.__tw }); });
  window.__opaque = true;
  // each WebGL context remembered on its canvas, so the window can let go of it the moment this preview is replaced
  const gc = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (type, ...a) { const c = gc.call(this, type, ...a); if (c && String(type).indexOf('webgl') === 0) this.__twGL = c; return c; };
})();
