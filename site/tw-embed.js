// Runs a real Tidewall wall inside a web page. The page plays Tidewall's part: the elements you name are the
// "windows", and the wall grows, parts and settles around them as they move, scroll or resize.
//
//   const wall = TW.mount(hostEl, { wall: 'inkmap', windows: () => [...elements], margin: 24 });
//   TW.draggable(panelEl, { within: hostEl, onMove: () => wall.update(true), onDrop: () => wall.update(false) });
//
// Rects go to the wall in its own device pixels, relative to the wall's box. Off screen or in a hidden tab the wall
// rests (Tidewall's own "pause"), so a page full of walls costs nothing while you aren't looking at them.
(() => {
  const base = (document.currentScript && document.currentScript.src.replace(/[^/]*$/, '')) || '';

  function mount(host, o) {
    const dpr = o.dpr || Math.min(2, window.devicePixelRatio || 1);
    // a wall's page in a frame, under everything else in the host (the panels that act as windows sit on top of it)
    function make(wall, variant) {
      const f = document.createElement('iframe');
      f.title = o.title || 'A live Tidewall wall';
      f.setAttribute('aria-hidden', 'true');
      f.tabIndex = -1;
      f.src = `${base}walls/${wall}.html?wallpaper=1&pdpr=${dpr}${variant ? '&v=' + variant : ''}`;   // (as the app loads them)
      f.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;border:0;pointer-events:none;opacity:0;transition:opacity .6s ease;z-index:0';
      host.insertBefore(f, host.firstChild);
      return f;
    }
    // the wall showing, and the one coming in beneath it (a swap hands over as the app does: the old one stays until
    // the new one is drawn, then fades)
    let frame = make(o.wall, o.variant), coming = null, wall = o.wall;

    let ready = false, paused = false, last = '', raf = 0, liveT = 0, seen = true;
    const post = m => frame.contentWindow && frame.contentWindow.postMessage({ __tw: JSON.stringify(m) }, '*');
    const box = () => host.getBoundingClientRect();

    function rects() {
      const b = box(), m = o.margin ?? 24, els = (o.windows ? o.windows() : []).filter(Boolean);
      return els.map(el => el.getBoundingClientRect())
        .filter(r => r.width > 0 && r.right > b.left && r.left < b.right && r.bottom > b.top && r.top < b.bottom)
        .map(r => ({ l: (r.left - b.left), t: (r.top - b.top), r: (r.right - b.left), b: (r.bottom - b.top), m }));
    }
    function send(live) {
      if (!ready) return;
      const R = v => Math.round(v * dpr), rs = rects();
      const key = JSON.stringify(rs) + live;
      if (key === last) return;
      last = key;
      post({ t: 'windows', live, r: rs.map(q => [R(q.l), R(q.t), R(q.r), R(q.b)]), n: rs.map(() => ''), sm: rs.map(() => 0) });
      post({ t: 'icons', vis: true, r: rs.map(q => [R(q.l - q.m), R(q.t - q.m), R(q.r + q.m), R(q.b + q.m)]) });
    }
    // live while things move; one settled update shortly after they stop (that's what plays the wall's slow morph)
    function update(live) {
      if (live) {
        if (!raf) raf = requestAnimationFrame(() => { raf = 0; send(true); });
        clearTimeout(liveT);
        liveT = setTimeout(() => send(false), 160);
      } else { cancelAnimationFrame(raf); raf = 0; send(false); }
    }
    function desk() {
      const b = box(), W = Math.round(b.width * dpr), H = Math.round(b.height * dpr);
      post({ t: 'desk', x: 0, y: 0, w: W, h: H, uw: W, uh: H, i: 0, n: 1, mx: W / 2, my: H / 2, mw: W, mh: H });
    }
    function rest(v) { if (v !== paused && ready) { paused = v; post({ t: 'pause', v }); } }
    const restIfHidden = () => rest(document.hidden || !seen);

    addEventListener('message', e => {
      if (!e.data || String(e.data.__twFrom) !== 'ready') return;
      if (coming && e.source === coming.contentWindow) {
        const old = frame; frame = coming; coming = null;
        old.style.zIndex = 1; old.style.opacity = 0; setTimeout(() => old.remove(), 700);
        paused = false;
      } else if (e.source !== frame.contentWindow) return;
      ready = true;
      desk();
      post({ t: 'me', seed: o.seed ?? 7 });
      last = ''; send(false);
      requestAnimationFrame(() => { frame.style.opacity = 1; });   // (the land rises from here: no need to wait)
      restIfHidden();
      o.onReady && o.onReady();
    });
    // the pointer, for walls with something that follows it (the boat, footprints)
    if (o.cursor !== false) {
      host.addEventListener('pointermove', e => {
        if (!ready) return;
        const b = box();
        post({ t: 'cursor', x: Math.round((e.clientX - b.left) * dpr), y: Math.round((e.clientY - b.top) * dpr) });
      });
      host.addEventListener('pointerleave', () => ready && post({ t: 'cursorOff' }));
    }
    new ResizeObserver(() => { if (ready) { desk(); last = ''; send(false); } }).observe(host);
    new IntersectionObserver(es => { seen = es[0].isIntersecting; restIfHidden(); }).observe(host);
    document.addEventListener('visibilitychange', restIfHidden);
    if (o.followScroll) addEventListener('scroll', () => update(true), { passive: true });
    function swap(next, variant) {
      if (next === wall && !coming) return;
      wall = next;
      if (coming) coming.remove();
      coming = make(next, variant);
    }
    return { update, swap, get frame() { return frame; }, get wall() { return wall; }, get ready() { return ready; } };
  }

  // A panel you can drag (pointer or arrow keys), kept inside `within`. Moves with a transform, so nothing reflows.
  function draggable(el, o = {}) {
    let x = 0, y = 0, sx = 0, sy = 0, x0 = 0, y0 = 0, drag = false;
    const set = () => { el.style.transform = `translate3d(${x}px, ${y}px, 0)`; };
    const clampToBox = () => {
      if (!o.within) return;
      const b = o.within.getBoundingClientRect(), r = el.getBoundingClientRect();
      const dx = Math.min(0, b.right - r.right) + Math.max(0, b.left - r.left);
      const dy = Math.min(0, b.bottom - r.bottom) + Math.max(0, b.top - r.top);
      x += dx; y += dy;
    };
    el.style.touchAction = 'none';
    el.addEventListener('pointerdown', e => {
      if (o.handle && !e.target.closest(o.handle)) return;
      if (e.target.closest('a,button,input')) return;
      drag = true; sx = e.clientX; sy = e.clientY; x0 = x; y0 = y;
      el.setPointerCapture(e.pointerId); el.classList.add('is-dragging'); o.onStart && o.onStart();
    });
    el.addEventListener('pointermove', e => {
      if (!drag) return;
      x = x0 + e.clientX - sx; y = y0 + e.clientY - sy; set(); clampToBox(); set();
      o.onMove && o.onMove();
    });
    const end = () => { if (!drag) return; drag = false; el.classList.remove('is-dragging'); o.onDrop && o.onDrop(); };
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);
    el.addEventListener('keydown', e => {
      const k = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
      if (!k || e.target !== el) return;
      e.preventDefault();
      const s = e.shiftKey ? 60 : 16;
      x += k[0] * s; y += k[1] * s; set(); clampToBox(); set();
      o.onMove && o.onMove(); o.onDrop && o.onDrop();
    });
    return { moveTo(nx, ny) { x = nx; y = ny; set(); clampToBox(); set(); }, get x() { return x; }, get y() { return y; } };
  }

  window.TW = { mount, draggable };
})();
