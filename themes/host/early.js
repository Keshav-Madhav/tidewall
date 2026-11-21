// Runs in every wallpaper page before the page's own scripts. The app calls it with
// { fps, opaque, cap, maxHz, profile }: the frame rate picked in Settings (0 = Auto), whether the scene covers every
// pixel, the theme's sharpness cap, the display's refresh rate, and whether to time each frame.
(HOST => {
  const post = m => webkit.messageHandlers.host.postMessage(m);

  // The theme's sharpness cap: the page sees a devicePixelRatio no higher than it (the host scales its messages the same).
  if (HOST.cap < 8) {
    const pd = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio') || Object.getOwnPropertyDescriptor(Window.prototype, 'devicePixelRatio');
    const real = pd && pd.get ? () => pd.get.call(window) : () => 2;
    try { Object.defineProperty(window, 'devicePixelRatio', { get: () => Math.min(real(), HOST.cap), configurable: true }); } catch (_) {}
  }

  // A WebGL page whose context is lost (displays sleeping and waking, a monitor reconnecting, a GPU switch) would show
  // only its CSS background for good. When a canvas in the document loses its context, tell the host and reload,
  // sooner if the context comes back by itself (its textures and buffers are gone either way).
  (() => {
    const getContext = HTMLCanvasElement.prototype.getContext, watched = [];
    let timer = 0;
    const lost = () => {
      try { post('JSERR webgl context lost; reloading the page'); } catch (_) {}
      // a page that keeps losing it waits longer each time, so a loss can never become a reload loop
      let recent = 0;
      try {
        const r = JSON.parse(sessionStorage.__twLost || '[]').filter(x => Date.now() - x < 120000);
        r.push(Date.now());
        sessionStorage.__twLost = JSON.stringify(r);
        recent = r.length;
      } catch (_) {}
      clearTimeout(timer);
      timer = setTimeout(() => location.reload(), recent > 3 ? 30000 : recent > 1 ? 8000 : 2500);
    };
    HTMLCanvasElement.prototype.getContext = function (type, ...rest) {
      const ctx = getContext.call(this, type, ...rest);
      if (ctx && String(type).startsWith('webgl') && !this.__twWatched) {
        this.__twWatched = true;
        watched.push(new WeakRef(this));
        this.addEventListener('webglcontextlost', e => { if (this.isConnected) { e.preventDefault(); lost(); } });
        this.addEventListener('webglcontextrestored', () => { if (this.isConnected) { clearTimeout(timer); location.reload(); } });
      }
      return ctx;
    };
    // asked by the host after the displays wake
    window.__twGLLost = () => watched.some(ref => {
      const c = ref.deref();
      if (!c || !c.isConnected) return false;
      const g = getContext.call(c, 'webgl2') || getContext.call(c, 'webgl');
      return !!(g && g.isContextLost());
    });
  })();

  // The WebView2 surface the pages were written against.
  const listeners = [];
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage: m => post(typeof m === 'string' ? m : JSON.stringify(m)),
    addEventListener: (t, f) => { if (t === 'message') listeners.push(f); },
    removeEventListener: () => {},
  };
  window.__hostSend = s => { for (const f of listeners) f({ data: s }); };
  addEventListener('error', e => post('JSERR ' + e.message + ' ' + (e.filename || '').split('/').pop() + ':' + e.lineno));
  window.__opaque = HOST.opaque;
  if (HOST.profile) window.__prof = { n: 0, ms: 0, t0: performance.now() };

  // WebGL contexts: no depth or stencil buffers (no theme uses them); opaque when the scene covers every pixel, so
  // WindowServer copies instead of blending; and always the low-power GPU, so a wallpaper never wakes a discrete one.
  const getContext = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (type, opts) {
    if (type === 'webgl2' && !window.__gl) {
      window.__gl = getContext.call(this, type, Object.assign({}, opts,
        { stencil: false, depth: false, alpha: window.__opaque === false, powerPreference: 'low-power' }));
      return window.__gl;
    }
    return getContext.call(this, type, String(type).startsWith('webgl') ? Object.assign({ powerPreference: 'low-power' }, opts) : opts);
  };

  // Frame pacing. Left alone every page would draw at the display's refresh and the slow ambient ones would wake 120
  // times a second to skip most frames. Instead a page rests at a calm rate (30, or less if it asks: window.__twCalm),
  // gets every frame the display shows while a window is dragged or the scene settles (window.__twSettle: a morph,
  // beds easing, a cross-fade; tools/smooth.sh measures it), and 60 while the pointer is over the wallpaper (120 there
  // cost 3-5 points of CPU, and the pointer can wander for minutes). A rate picked in Settings replaces all of it:
  // 60 holds every scene at 60, 30/20/15 cap it. Between frames the page sleeps on a timer rather than every vsync.
  const pick = HOST.fps;
  const CALM = pick > 0 ? pick : 30;
  const LIVE = pick > 0 ? pick : Math.max(60, HOST.maxHz);
  const HOVER = Math.min(LIVE, 60);
  const calmRate = () => pick >= 60 ? pick : Math.min(CALM, window.__twCalm || CALM);
  let boostUntil = 0, hoverUntil = 0, settleUntil = 0;
  let paceK = 1;   // 2 on battery when Settings says calmer
  const extend = (until, ms) => Math.max(until, performance.now() + ms);

  // fast movers keep each step small by moving no faster than the frames they can get allow
  window.__twMaxRate = () => LIVE / paceK;
  window.__twHover = ms => { const was = rateNow(); hoverUntil = extend(hoverUntil, ms); if (rateNow() > was) hurry(); };
  window.__twBoost = ms => { const was = rateNow(); boostUntil = extend(boostUntil, ms); if (rateNow() > was) hurry(); };
  window.__twSettle = ms => { settleUntil = extend(settleUntil, ms); window.__twBoost(ms); };
  window.__twSettling = () => performance.now() < settleUntil;

  const deliver = window.__hostSend;
  window.__hostSend = s => {
    if (s.startsWith('{"t":"pace"')) { paceK = +JSON.parse(s).k || 1; return; }
    const pointer = s.startsWith('{"t":"cursor"') && s.charCodeAt(13) === 44;   // {"t":"cursor", (not cursorOff)
    if (s.startsWith('{"t":"dicons"')) window.__dicons = s;                     // read by the bench probes
    if (pointer) window.__twOver = s.indexOf('"w":1') >= 0;                     // over a window, not the wallpaper
    if (window.__live) window.__twBoost(900);
    else if (pointer && !window.__twOver) window.__twHover(900);
    deliver(s);
  };

  const raf = window.requestAnimationFrame.bind(window);
  let due = 0, lastT = -1, go = false;
  function rateNow() { const now = performance.now(); return now < boostUntil ? LIVE : now < hoverUntil ? Math.max(HOVER, calmRate()) : calmRate(); }
  // A loop that isn't due for a while sleeps on a timer rather than waking at every vsync to find it isn't due yet.
  // A drag or the pointer arriving wakes the sleepers at once: the first frames of a move never wait out a calm step.
  const sleeping = new Map();
  const sleep = (tick, wait) => { const id = setTimeout(() => { sleeping.delete(id); raf(tick); }, wait); sleeping.set(id, tick); };
  function hurry() {
    if (!sleeping.size) return;
    due = Math.min(due, performance.now());
    for (const [id, tick] of sleeping) { clearTimeout(id); raf(tick); }
    sleeping.clear();
  }
  window.requestAnimationFrame = cb => {
    const wait = due - performance.now() - 6;
    if (wait > 4) sleep(tick, wait); else raf(tick);
    function tick(t) {
    if (t !== lastT) {
      lastT = t;
      const step = paceK * 1000 / rateNow();
      go = t + 2 >= due;
      if (go) due = due + step < t ? t + step : due + step;          // back from a rest: the next frame is a step away, not the next vsync
    }
    if (!go) {
      const wait = due - t - 6;
      if (wait > 4) sleep(tick, wait); else raf(tick);
      return;
    }
    if (!window.__prof) return cb(t);
    const start = performance.now();
    cb(t);
    window.__prof.n++;
    window.__prof.ms += performance.now() - start;
    }
  };
})
