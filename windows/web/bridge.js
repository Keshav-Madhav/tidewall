// Runs first in every Tidewall page on Windows. The pages talk to their host through WebKit's message handlers (the
// macOS app's); here those post into WebView2's own channel, tagged with the handler's name.
(() => {
  const native = window.chrome && window.chrome.webview;
  if (!native || window.webkit) return;
  const send = (channel, m) => native.postMessage(channel + '\u0001' + (typeof m === 'string' ? m : JSON.stringify(m)));
  window.webkit = { messageHandlers: { host: { postMessage: m => send('host', m) }, ui: { postMessage: m => send('ui', m) } } };
})();
