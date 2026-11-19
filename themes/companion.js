// Tidewall companions, shared by the themes (load in <head>, before the page's own scripts).
//  · DLWake: a continuous wake — two lines streaming from the stern that spread and fade with age.
//    Points are only laid while the boat really travels, so a resting boat leaves no wake.
//  · Beach / Meadow: window changes glide. Each window rect eases toward where it really is and the page
//    re-solves its land field every frame (its own refresh), instead of cross-fading between two fields.
//  · Beach: a kayak paddles after your cursor. Meadow: a butterfly flutters after it.
'use strict';
(() => {
const NS = 'http://www.w3.org/2000/svg';

/* ---------------- wake ---------------- */
window.DLWake = function (color, width = 1, life = 1.7, spreadRate = 16) {
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('style', 'position:fixed;inset:0;width:100%;height:100%;pointer-events:none;overflow:visible');
  const BUCKETS = 8, paths = [];
  for (let b = 0; b < BUCKETS; b++) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('fill', 'none'); p.setAttribute('stroke', color); p.setAttribute('stroke-width', width);
    p.setAttribute('stroke-linecap', 'round'); p.setAttribute('opacity', (1 - b / BUCKETS) * .85);
    svg.appendChild(p); paths.push(p);
  }
  const pts = [];
  let lastX = null, lastY = null;
  const attach = () => { if (!svg.isConnected && document.body) document.body.appendChild(svg); };
  return {
    el: svg,
    // call every frame with the stern position and heading; adds a point only after real travel
    feed(x, y, ang, now) {
      attach();
      if (lastX === null || Math.hypot(x - lastX, y - lastY) > 4) { pts.push({ x, y, a: ang, t: now }); lastX = x; lastY = y; }
    },
    reset() { lastX = lastY = null; },
    draw(now) {
      while (pts.length && now - pts[0].t > life * 1000) pts.shift();
      const ds = paths.map(() => '');
      for (let i = 1; i < pts.length; i++) {
        const p = pts[i - 1], q = pts[i], age = (now - q.t) / 1000 / life, b = Math.min(BUCKETS - 1, Math.floor(age * BUCKETS));
        const sp = (u, side) => { const s = 2.5 + ((now - u.t) / 1000) * spreadRate, nx = -Math.sin(u.a) * s * side, ny = Math.cos(u.a) * s * side; return `${(u.x + nx).toFixed(1)},${(u.y + ny).toFixed(1)}`; };
        ds[b] += `M${sp(p, 1)}L${sp(q, 1)}M${sp(p, -1)}L${sp(q, -1)}`;
      }
      paths.forEach((p, b) => p.setAttribute('d', ds[b]));
      return pts.length > 0;
    },
  };
};

/* ---------------- which theme are we in (decided once the page's scripts ran) ---------------- */
const isBeach = () => typeof stepKayaks === 'function' && typeof curS === 'function';
const isMeadow = () => typeof prepareMeadowBoy === 'function';

/* ---------------- gliding windows for Beach / Meadow ---------------- */
const send0 = window.__hostSend;
if (send0) {
  let cur = null, tgt = null, anim = false, last = 0, liveUntil = 0;
  const center = r => [(r[0] + r[2]) / 2, (r[1] + r[3]) / 2];
  // keep each window in its own slot even when the z-order (and so the list order) changes
  const matchTo = (from, to) => {
    const used = new Set(), out = [];
    for (const r of from) {
      let bi = -1, bd = 1e18; const [cx, cy] = center(r);
      to.forEach((t, i) => { if (used.has(i)) return; const [tx, ty] = center(t), d = (tx - cx) ** 2 + (ty - cy) ** 2 + ((t[2] - t[0]) - (r[2] - r[0])) ** 2 + ((t[3] - t[1]) - (r[3] - r[1])) ** 2; if (d < bd) { bd = d; bi = i; } });
      used.add(bi); out.push(to[bi]);
    }
    return out;
  };
  let gen = 0, lastSend = 0;
  const step = (now, g = gen) => {
    if (g !== gen) return;
    const dt = last ? Math.min((now - last) / 1000, .05) : 1 / 60; last = now;
    const live = now < liveUntil, k = 1 - Math.exp(-dt * (live ? 40 : 6));
    let moving = false;
    for (let i = 0; i < cur.length; i++) for (let j = 0; j < 4; j++) {
      const d = tgt[i][j] - cur[i][j];
      if (Math.abs(d) > .5) { cur[i][j] += d * k; moving = true; } else cur[i][j] = tgt[i][j];
    }
    if (!moving || now - lastSend > 30) {
      lastSend = now;
      const prev = window.__live; window.__live = true;              // the page's commit() then re-solves instantly
      send0(JSON.stringify({ t: 'icons', vis: true, r: cur.map(r => r.map(Math.round)) }));
      window.__live = prev;
    }
    if (moving) requestAnimationFrame(t => step(t, g)); else anim = false;
  };
  window.__hostSend = s => {
    let m; try { m = JSON.parse(s); } catch (_) { return send0(s); }
    if (m.t === 'cursor') companionCursor(m);
    if (m.t !== 'icons' || !(isBeach() || isMeadow())) return send0(s);
    const rects = m.vis ? m.r : [];
    const hasField = typeof FB !== 'undefined' && FB;
    if (!hasField || !cur || rects.length !== cur.length) {     // first layout, or a window came/went: the page's own morph
      cur = rects.map(r => r.slice()); tgt = cur.map(r => r.slice()); anim = false; gen++; return send0(s);
    }
    tgt = matchTo(cur, rects).map(r => r.slice());
    if (window.__live) liveUntil = performance.now() + 250;
    if (!anim) { anim = true; last = 0; const g = gen; requestAnimationFrame(t => step(t, g)); }
  };
}

/* ---------------- cursor companions ---------------- */
let cursor = null, started = false;
// where this display sits in a world of several (span.js); the cursor is kept in world coordinates
const offX = () => typeof OX !== 'undefined' ? OX : 0, offY = () => typeof OY !== 'undefined' ? OY : 0;
const W0 = () => window.Span && Span.world;
function cursorAt(x, y) {
  const moved = !cursor || Math.hypot(x - cursor.x, y - cursor.y) > 2;
  cursor = { x, y, t: moved ? performance.now() : cursor.t };
  if (!started && document.readyState !== 'loading') start();
}
function companionCursor(m) {
  const k = devicePixelRatio || 1, x = m.x / k + offX(), y = m.y / k + offY();
  cursorAt(x, y); if (W0()) Span.post('ccur', { x, y });
}
if (window.Span) Span.on('ccur', m => cursorAt(m.x, m.y));
function sprite(w, h) {
  const c = document.createElement('canvas'), k = devicePixelRatio || 1;
  c.width = Math.round(w * k); c.height = Math.round(h * k);
  c.style.cssText = `position:fixed;left:0;top:0;width:${w}px;height:${h}px;pointer-events:none;will-change:transform;opacity:0;transition:opacity 1s ease`;
  document.body.appendChild(c); const x = c.getContext('2d'); x.scale(k, k); return { c, x, w, h };
}
function start() {
  if (started) return;
  if (isBeach()) { started = true; kayak(); }
  else if (isMeadow()) { started = true; butterfly(); }
}
addEventListener('load', () => setTimeout(() => { if (cursor) start(); }, 0));

// Beach: a yellow kayak with a red paddle, like the ones already out on the water
function kayak() {
  const S = sprite(56, 30), wake = DLWake('rgba(255,255,255,0.9)', 1.3, 1.9, 12);
  const B = { x: 0, y: 0, vx: 0, vy: 0, a: 0, ph: 0, on: false };
  const water = (x, y) => curS(x, y);
  const grad = (x, y) => [water(x + 8, y) - water(x - 8, y), water(x, y + 8) - water(x, y - 8)];
  const toWater = (x, y, need) => { let s = water(x, y); for (let i = 0; i < 90 && s < need; i++) { const [gx, gy] = grad(x, y), l = Math.hypot(gx, gy) || 1; x += gx / l * 8; y += gy / l * 8; s = water(x, y); } return [x, y]; };
  const draw = paddle => {
    const x = S.x; x.clearRect(0, 0, S.w, S.h); x.save(); x.translate(28, 15);
    x.fillStyle = '#f1c232'; x.strokeStyle = 'rgba(120,80,20,0.8)'; x.lineWidth = 1;
    x.beginPath(); x.moveTo(-22, 0); x.quadraticCurveTo(-8, -6.5, 0, -6.5); x.quadraticCurveTo(10, -6.5, 22, 0); x.quadraticCurveTo(10, 6.5, 0, 6.5); x.quadraticCurveTo(-8, 6.5, -22, 0); x.closePath(); x.fill(); x.stroke();
    x.fillStyle = 'rgba(60,40,20,0.85)'; x.beginPath(); x.ellipse(-1, 0, 5, 3.6, 0, 0, 7); x.fill();
    x.fillStyle = '#3d2a1b'; x.beginPath(); x.arc(-1, 0, 2.6, 0, 7); x.fill();
    x.rotate(paddle); x.strokeStyle = '#3d2a1b'; x.lineWidth = 1.2; x.beginPath(); x.moveTo(0, -13); x.lineTo(0, 13); x.stroke();
    x.fillStyle = '#c0392b'; for (const s of [-1, 1]) { x.beginPath(); x.ellipse(0, s * 13, 1.9, 3.6, 0, 0, 7); x.fill(); }
    x.restore();
  };
  let last = 0, rest = 0;
  const later = () => setTimeout(() => requestAnimationFrame(tick), 300);   // nothing to draw: look in again shortly
  const tick = now => {
    const dt = last ? Math.min((now - last) / 1000, .05) : 1 / 60; last = now;
    if (typeof FB === 'undefined' || !FB || (typeof paused !== 'undefined' && paused)) { last = 0; return later(); }
    if (W0() && !Span.leader()) {                                       // another display paddles it: show where it is
      const r = remoteKayak;
      if (r && r !== shownK) { shownK = r; quietK = 0; B.x = r[0]; B.y = r[1]; B.a = r[2]; B.ph = r[3]; const sp = r[4]; B.on = true; S.c.style.opacity = 1;
        draw(Math.sin(B.ph * 2.2) * .55 * Math.min(1, sp / 40 + .15)); place(sp, now); }
      else if (++quietK > 30) { wake.draw(now); return later(); }        // nothing new for a while: look in now and then
      return requestAnimationFrame(tick);
    }
    if (!B.on) { const [mx, my, , mh] = W0() ? Span.main : [W * .5, H * .5, 0, H * .5]; [B.x, B.y] = toWater(mx, my + mh * .25, 120); B.on = true; S.c.style.opacity = 1; }
    const [tx, ty] = cursor ? toWater(cursor.x, cursor.y, 60) : [B.x, B.y];
    const dx = tx - B.x, dy = ty - B.y, d = Math.hypot(dx, dy), maxV = 140;
    const want = d < 10 ? 0 : Math.min(maxV, (d - 10) * 1.6);
    let dvx = d > 1 ? dx / d * want : 0, dvy = d > 1 ? dy / d * want : 0;
    const ax = B.x + B.vx * .45, ay = B.y + B.vy * .45, sa = water(ax, ay);
    if (sa < 55) { const [gx, gy] = grad(ax, ay), l = Math.hypot(gx, gy) || 1, push = (55 - sa) * 3; dvx += gx / l * push; dvy += gy / l * push; }
    const acc = 260 * dt; let ex = dvx - B.vx, ey = dvy - B.vy; const el = Math.hypot(ex, ey); if (el > acc) { ex *= acc / el; ey *= acc / el; }
    B.vx += ex; B.vy += ey; B.x += B.vx * dt; B.y += B.vy * dt;
    const sp = Math.hypot(B.vx, B.vy);
    if (sp > 6) { let da = Math.atan2(B.vy, B.vx) - B.a; da = Math.atan2(Math.sin(da), Math.cos(da)); B.a += da * Math.min(1, dt * 5); }
    if (sp < .3 && d < 12) { if (rest++ > 2) { if (W0()) Span.post('ckay', { b: [B.x, B.y, B.a, B.ph, 0] }); return later(); } } else rest = 0;   // at rest: last frame already shows it (and a display that just came back learns where it is)
    B.ph += dt * (2 + sp / 30);
    draw(Math.sin(B.ph * 2.2) * .55 * Math.min(1, sp / 40 + .15));
    place(sp, now);
    if (W0() && now - sentK > 30) { sentK = now; Span.post('ckay', { b: [B.x, B.y, B.a, B.ph, sp] }); }
    requestAnimationFrame(tick);
  };
  let remoteKayak = null, sentK = 0, shownK = null, quietK = 0; if (window.Span) Span.on('ckay', m => { remoteKayak = m.b; });
  const place = (sp, now) => { const x = B.x - offX(), y = B.y - offY();
    S.c.style.transform = `translate3d(${(x - 28).toFixed(1)}px,${(y - 15).toFixed(1)}px,0) rotate(${B.a.toFixed(3)}rad)`;
    if (sp > 22) wake.feed(x - Math.cos(B.a) * 20, y - Math.sin(B.a) * 20, B.a, now); else wake.reset();
    wake.draw(now); };
  requestAnimationFrame(tick);
}

// Meadow: a butterfly that flutters after the cursor and circles it when it arrives
function butterfly() {
  const S = sprite(34, 30), sh = sprite(34, 30);
  sh.c.style.filter = 'blur(1.5px)';
  const B = { x: innerWidth * .6 + offX(), y: innerHeight * .4 + offY(), vx: 0, vy: 0, a: 0, t: 0 };
  let remoteB = null, sentB = 0, shownB = null, quietB = 0; if (window.Span) Span.on('cfly', m => { remoteB = m.b; });
  const wings = (x, flap, shadow) => {
    x.clearRect(0, 0, 34, 30); x.save(); x.translate(17, 15);
    const sx = .25 + .75 * Math.abs(Math.cos(flap));
    for (const s of [-1, 1]) {
      x.save(); x.scale(s * sx, 1);
      x.fillStyle = shadow ? 'rgba(20,40,10,0.28)' : '#e9a23b'; x.strokeStyle = shadow ? 'transparent' : 'rgba(70,40,20,0.85)'; x.lineWidth = .9;
      x.beginPath(); x.moveTo(1, -1); x.bezierCurveTo(6, -14, 16, -12, 14, -3); x.bezierCurveTo(13, 0, 6, 1, 1, 0); x.fill(); x.stroke();
      if (!shadow) x.fillStyle = '#c9573f';
      x.beginPath(); x.moveTo(1, 1); x.bezierCurveTo(5, 2, 12, 5, 9, 11); x.bezierCurveTo(6, 13, 2, 8, 1, 1); x.fill(); x.stroke();
      if (!shadow) { x.fillStyle = 'rgba(255,248,225,0.9)'; x.beginPath(); x.arc(10, -6, 1.5, 0, 7); x.fill(); x.fillStyle = '#3e6f7d'; x.beginPath(); x.arc(6, -8, 1.2, 0, 7); x.fill(); }
      x.restore();
    }
    if (!shadow) { x.fillStyle = '#3d2a1b'; x.beginPath(); x.ellipse(0, 0, 1.3, 6.5, 0, 0, 7); x.fill();
      x.strokeStyle = '#3d2a1b'; x.lineWidth = .6; x.beginPath(); x.moveTo(0, -6); x.quadraticCurveTo(-2, -10, -3.5, -11); x.moveTo(0, -6); x.quadraticCurveTo(2, -10, 3.5, -11); x.stroke(); }
    x.restore();
  };
  let last = 0, landed = false;
  S.c.style.opacity = 1; sh.c.style.opacity = 1;
  const later = () => setTimeout(() => requestAnimationFrame(tick), 300);
  const tick = now => {
    const dt = last ? Math.min((now - last) / 1000, .05) : 1 / 60; last = now;
    if (typeof paused !== 'undefined' && paused) { last = 0; return later(); }
    if (W0() && !Span.leader()) {                                       // another display flies it: show where it is
      const r = remoteB;
      if (r && r !== shownB) { shownB = r; quietB = 0; [B.x, B.y, B.a, B.t] = r; const fl = r[4] ? Math.PI / 2 : B.t * (14 + Math.min(10, r[5] / 25)); wings(S.x, fl, false); wings(sh.x, fl, true); placeB(); }
      else if (++quietB > 30) return later();                            // landed, or nothing new: rest
      return requestAnimationFrame(tick);
    }
    // your cursor has been still for a while: it settles, wings folded, and stops drawing until the cursor moves
    const quiet = !cursor || now - (cursor.t || 0) > 20000;
    if (quiet && landed) { last = 0; if (W0() && Span.leader()) Span.post('cfly', { b: [B.x, B.y, B.a, B.t, 1, 0] }); return later(); }
    if (quiet && Math.hypot(B.vx, B.vy) < 40) { landed = true; wings(S.x, Math.PI / 2, false); wings(sh.x, Math.PI / 2, true); if (W0()) Span.post('cfly', { b: [B.x, B.y, B.a, B.t, 1, 0] }); return later(); }
    landed = false;
    B.t += dt;
    // aim a little off the cursor, drifting round it, so it hovers rather than sitting on the pointer
    const orbit = 26 + 10 * Math.sin(B.t * .7);
    const tx = (cursor ? cursor.x : B.x) + Math.cos(B.t * 1.3) * orbit, ty = (cursor ? cursor.y : B.y) + Math.sin(B.t * 1.7) * orbit * .6 - 14;
    const dx = tx - B.x, dy = ty - B.y;
    B.vx += (dx * 5 - B.vx * 2.6) * dt + Math.sin(B.t * 9.3) * 40 * dt; B.vy += (dy * 5 - B.vy * 2.6) * dt + Math.cos(B.t * 7.1) * 60 * dt;
    const sp = Math.hypot(B.vx, B.vy), maxV = 320; if (sp > maxV) { B.vx *= maxV / sp; B.vy *= maxV / sp; }
    B.x += B.vx * dt; B.y += B.vy * dt;
    let da = Math.atan2(B.vy, B.vx) + Math.PI / 2 - B.a; da = Math.atan2(Math.sin(da), Math.cos(da)); B.a += da * Math.min(1, dt * 4);
    const flap = B.t * (14 + Math.min(10, sp / 25));
    wings(S.x, flap, false); wings(sh.x, flap, true);
    placeB();
    if (W0() && now - sentB > 30) { sentB = now; Span.post('cfly', { b: [B.x, B.y, B.a, B.t, 0, sp] }); }
    requestAnimationFrame(tick);
  };
  const placeB = () => { const x = B.x - offX(), y = B.y - offY();
    S.c.style.transform = `translate3d(${(x - 17).toFixed(1)}px,${(y - 15).toFixed(1)}px,0) rotate(${B.a.toFixed(3)}rad)`;
    sh.c.style.transform = `translate3d(${(x - 17 + 22).toFixed(1)}px,${(y - 15 + 28).toFixed(1)}px,0) rotate(${B.a.toFixed(3)}rad) scale(.85)`; };
  requestAnimationFrame(tick);
}
})();
