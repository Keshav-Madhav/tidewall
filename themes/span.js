/* One world across displays: the shared plumbing for themes that span.

   Displays showing the same spanning theme form one world: the host's `desk` message gives this page its place in
   it (x, y), the world's size (uw, uh) and every display's frame in it (fr, points, relative to the world's corner).
   A spanning theme lays out the WHOLE world (identically on every page: same seed, same windows) and draws only its
   own slice. What moves (trains, fish, boats) is run by one page, the leader, which broadcasts it to the others.

   Span.world        true when this page is one of several in a world
   Span.desk(m)      feed it every `desk` message
   Span.x/y/uw/uh    this page's corner in the world, and the world's size
   Span.frames()     every display in the world, [x, y, w, h]
   Span.gaps()       the parts of the world's bounding box no display shows (lay nothing there)
   Span.edges(f)     the edges of frame f that face the outside (not another display), for borders
   Span.leader()     whether this page runs the movers (lowest-numbered live, unpaused page)
   Span.post(t, d)   / Span.on(t, fn)   messages between the world's pages (same theme only)
   Span.paused(v)    tell the others this page is paused, so leadership moves to a page that runs
  Span.secs(wrap)   the world's clock in seconds (the wall clock: the same on every page), wrapped to keep
                    float32 shader time precise; animated water, light and wind must use it or they break at the seams
*/
(() => {
  const theme = (location.pathname.split('/').pop() || '').replace(/\.html$/, '');
  const ch = typeof BroadcastChannel === 'function' ? new BroadcastChannel('tidewall-world-' + theme) : null;
  let D = { x: 0, y: 0, uw: 0, uh: 0, i: 0, n: 1, fr: null }, pausedSelf = false, resumedAt = performance.now();
  // a page that has just loaded or resumed follows the current leader for a moment (taking its movers' positions)
  // before leading itself: otherwise it would lead from stale positions and everything would jump back
  const GRACE = 2500, inGrace = () => performance.now() - resumedAt < GRACE;
  const peers = new Map(), handlers = {};
  const key = () => (D.fr || []).map(f => f.join(',')).join(';');
  const send = (t, d) => { if (ch && D.fr && D.fr.length > 1) try { ch.postMessage(Object.assign({ t, from: D.i, key: key(), w: window.__twOver ? 1 : 0 }, d)); } catch (_) { } };   // w: the pointer is over one of your windows
  if (ch) ch.onmessage = e => {
    const m = e.data; if (!m || m.key !== key() || m.from === D.i) return;
    if (m.t === 'hb') { peers.set(m.from, { at: performance.now(), paused: !!m.paused, grace: !!m.grace }); return; }
    if ((m.t === 'cur' || m.t === 'ccur') && !m.w && window.__twHover) window.__twHover(900);   // the pointer is over this world on another display: keep up, at the pointer's rate (≤ 60)
    const f = handlers[m.t]; if (f) try { f(m); } catch (err) { try { webkit.messageHandlers.host.postMessage('JSERR span ' + m.t + ' ' + err.message); } catch (_) { } }
  };
  const beat = () => send('hb', { paused: pausedSelf, grace: inGrace() });
  setInterval(beat, 1000);

  // the world's bounding box cut into cells by every frame edge; cells no frame covers are gaps (merged along rows)
  function gaps() {
    const fr = D.fr || []; if (fr.length < 2) return [];
    const xs = [...new Set([0, D.uw, ...fr.flatMap(f => [f[0], f[0] + f[2]])])].sort((a, b) => a - b);
    const ys = [...new Set([0, D.uh, ...fr.flatMap(f => [f[1], f[1] + f[3]])])].sort((a, b) => a - b);
    const out = [];
    for (let j = 0; j < ys.length - 1; j++) {
      let run = null;
      for (let i = 0; i < xs.length - 1; i++) {
        const cx = (xs[i] + xs[i + 1]) / 2, cy = (ys[j] + ys[j + 1]) / 2;
        const covered = fr.some(f => cx > f[0] && cx < f[0] + f[2] && cy > f[1] && cy < f[1] + f[3]);
        if (!covered) { if (run) run.w = xs[i + 1] - run.x; else run = { x: xs[i], y: ys[j], w: xs[i + 1] - xs[i], h: ys[j + 1] - ys[j] }; }
        else if (run) { out.push(run); run = null; }
      }
      if (run) out.push(run);
    }
    return out.filter(r => r.w > 1 && r.h > 1);
  }
  // the parts of an edge [a, b] that no neighbouring display covers
  function open(a, b, cover) {
    let segs = [[a, b]];
    for (const [c, d] of cover) segs = segs.flatMap(([s, e]) => d <= s || c >= e ? [[s, e]] : [[s, Math.max(s, c)], [Math.min(e, d), e]].filter(([p, q]) => q - p > 2));
    return segs;
  }
  // each edge of frame f facing outside: { side: 'top'|'bottom'|'left'|'right', a, b } (along the edge, world coords)
  function edges(f) {
    const fr = D.fr || [[0, 0, D.uw, D.uh]], [x, y, w, h] = f, o = fr.filter(g => g !== f), E = 3, out = [];
    const near = (p, q) => Math.abs(p - q) < E;
    for (const [s, a, b] of open(x, x + w, o.filter(g => near(g[1] + g[3], y)).map(g => [g[0], g[0] + g[2]])).map(r => ['top', ...r])) out.push({ side: s, a, b });
    for (const [s, a, b] of open(x, x + w, o.filter(g => near(g[1], y + h)).map(g => [g[0], g[0] + g[2]])).map(r => ['bottom', ...r])) out.push({ side: s, a, b });
    for (const [s, a, b] of open(y, y + h, o.filter(g => near(g[0] + g[2], x)).map(g => [g[1], g[1] + g[3]])).map(r => ['left', ...r])) out.push({ side: s, a, b });
    for (const [s, a, b] of open(y, y + h, o.filter(g => near(g[0], x + w)).map(g => [g[1], g[1] + g[3]])).map(r => ['right', ...r])) out.push({ side: s, a, b });
    return out;
  }
  window.Span = {
    get world() { return !!(D.fr && D.fr.length > 1); },
    get x() { return this.world ? D.x : 0; }, get y() { return this.world ? D.y : 0; },
    get uw() { return this.world ? D.uw : innerWidth; }, get uh() { return this.world ? D.uh : innerHeight; },
    get i() { return D.i | 0; }, get n() { return this.world ? D.fr.length : 1; },
    get main() { return [D.mx, D.my, D.mw, D.mh]; },
    desk(m) { const was = key(); D = m; if (key() !== was) { peers.clear(); resumedAt = performance.now(); setTimeout(beat, GRACE + 30); } beat(); },
    frames() { return this.world ? D.fr.slice() : [[0, 0, innerWidth, innerHeight]]; },
    gaps, edges,
    leader() {
      if (!this.world) return true;
      if (pausedSelf) return false;
      const now = performance.now(), live = [...peers].filter(([, p]) => now - p.at < 3500 && !p.paused);
      if (inGrace() && live.some(([, p]) => !p.grace)) return false;      // just back: follow whoever is leading now
      for (const [i, p] of live) if (i < D.i && !p.grace) return false;
      return true;
    },
    secs(wrap = 16384) { return (Date.now() / 1000) % wrap; },          // the wall clock: the same on every page, never re-agreed
    paused(v) { if (v !== pausedSelf) { pausedSelf = v; if (!v) { resumedAt = performance.now(); setTimeout(beat, GRACE + 30); } beat(); } },
    post: send,
    on(t, f) { handlers[t] = f; },
  };
})();
