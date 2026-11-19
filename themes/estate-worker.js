// Estate city generator (runs in a Web Worker, draws into an OffscreenCanvas).
// Field → marching squares → hand-inked outlines with handwriting along the walls.
//   f(x,y) > 0 inside buildings.  f = min(road clearance, Voronoi-cell interior, carved notches,
//   parks, rings, windows).  Contours of f at 0 and at WALL give the two wall lines.
'use strict';
const INK = 'rgba(70,44,26,0.9)', INK_SOFT = 'rgba(70,44,26,0.5)', RED = 'rgba(118,34,26,0.88)', PAPER = 'rgba(238,224,192,1)';
const SERIF = '"Iowan Old Style", "Hoefler Text", Baskerville, serif';
const SCRIPT = '"Apple Chancery", "Snell Roundhand", "Iowan Old Style", serif';

function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const h2 = (x, y) => { const s = Math.sin(x * 127.1 + y * 311.7) * 43758.5453; return s - Math.floor(s); };
function vnoise(x, y) { const ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy, ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
  const a = h2(ix, iy), b = h2(ix + 1, iy), c = h2(ix, iy + 1), d = h2(ix + 1, iy + 1); return (a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy; }
const fbm = (x, y) => { let v = 0, a = .5; for (let i = 0; i < 4; i++) { v += a * vnoise(x, y); x = x * 2.03 + 7; y = y * 2.03 + 3; a *= .5; } return v; };

/* ---------- pseudo-latin for the walls ---------- */
const SYL = ['AV', 'DE', 'RE', 'EST', 'MAR', 'VI', 'TVM', 'BO', 'NVM', 'MEN', 'TI', 'BVS', 'RA', 'VE', 'LO', 'SA', 'QVA', 'COR', 'DIS', 'PER', 'AE',
  'LVX', 'NOX', 'SER', 'PENS', 'TV', 'LI', 'AN', 'IN', 'TER', 'MVN', 'DO', 'CA', 'STEL', 'LA', 'VIA', 'TVR', 'RIS', 'MAG', 'NA', 'OR', 'TVS'];
function textStream(R) { let s = ''; return n => { while (s.length < n) { let w = ''; const k = 1 + Math.floor(R() * 3); for (let i = 0; i < k; i++) w += SYL[Math.floor(R() * SYL.length)]; s += w + ' '; } const out = s.slice(0, n); s = s.slice(n); return out; }; }

/* ---------- roads ---------- */
function makeRoads(W, H, R, avoid) {
  const roads = [];
  const walk = (x, y, a, len, width, bend) => {
    const pts = [[x, y]]; let ph = R() * 100;
    for (let s = 0; s < len; s += 6) {
      a += (vnoise(ph + s * 0.004, 3.7) - .5) * bend;
      x += Math.cos(a) * 6; y += Math.sin(a) * 6; pts.push([x, y]);
      if (x < -60 || y < -60 || x > W + 60 || y > H + 60) break;
    }
    roads.push({ pts, width });
    return pts;
  };
  // avenues: long, gently curving, crossing the screen
  const nAv = 3 + Math.floor(R() * 2);
  for (let i = 0; i < nAv; i++) {
    const side = Math.floor(R() * 4), t = .15 + R() * .7;
    const [x, y, a] = side === 0 ? [W * t, -40, Math.PI / 2] : side === 1 ? [W + 40, H * t, Math.PI] : side === 2 ? [W * t, H + 40, -Math.PI / 2] : [-40, H * t, 0];
    walk(x, y, a + (R() - .5) * .9, 4000, 13, .12);
  }
  // streets branching off at angles
  const nSt = Math.round(W * H / 26000);
  for (let i = 0; i < nSt; i++) {
    const base = roads[Math.floor(R() * roads.length)].pts, p = base[Math.floor(R() * base.length)];
    const q = base[Math.min(base.length - 1, base.indexOf(p) + 1)] || p, ta = Math.atan2(q[1] - p[1], q[0] - p[0]);
    const a = ta + (R() < .5 ? 1 : -1) * (Math.PI / 2 + (R() - .5) * .8);
    walk(p[0], p[1], a, 120 + R() * 520, R() < .3 ? 9 : 7, .35);
  }
  return roads;
}

/* ---------- distance transform (chamfer) ---------- */
function distField(seed, gw, gh, C) {
  const INF = 1e9, d = new Float32Array(gw * gh);
  for (let i = 0; i < d.length; i++) d[i] = seed[i] ? 0 : INF;
  const a = C, b = C * Math.SQRT2;
  for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) { const i = y * gw + x; let v = d[i];
    if (x > 0) v = Math.min(v, d[i - 1] + a); if (y > 0) { v = Math.min(v, d[i - gw] + a); if (x > 0) v = Math.min(v, d[i - gw - 1] + b); if (x < gw - 1) v = Math.min(v, d[i - gw + 1] + b); } d[i] = v; }
  for (let y = gh - 1; y >= 0; y--) for (let x = gw - 1; x >= 0; x--) { const i = y * gw + x; let v = d[i];
    if (x < gw - 1) v = Math.min(v, d[i + 1] + a); if (y < gh - 1) { v = Math.min(v, d[i + gw] + a); if (x < gw - 1) v = Math.min(v, d[i + gw + 1] + b); if (x > 0) v = Math.min(v, d[i + gw - 1] + b); } d[i] = v; }
  return d;
}

/* ---------- marching squares → chained loops ---------- */
function contours(f, gw, gh, C, L) {
  // edge ids: horizontal edge (x,y)->(x+1,y) = 2*(y*gw+x); vertical (x,y)->(x,y+1) = 2*(y*gw+x)+1
  const segs = new Map(), pt = new Map();
  const interp = (i, j) => { const a = f[i] - L, b = f[j] - L; return a / (a - b); };
  const P = (id) => {
    let p = pt.get(id); if (p) return p;
    const cell = id >> 1, x = cell % gw, y = (cell / gw) | 0;
    if ((id & 1) === 0) { const t = interp(cell, cell + 1); p = [(x + t) * C, y * C]; } else { const t = interp(cell, cell + gw); p = [x * C, (y + t) * C]; }
    pt.set(id, p); return p;
  };
  const link = (a, b) => { (segs.get(a) || segs.set(a, []).get(a)).push(b); (segs.get(b) || segs.set(b, []).get(b)).push(a); };
  for (let y = 0; y < gh - 1; y++) for (let x = 0; x < gw - 1; x++) {
    const i = y * gw + x, a = f[i] > L, b = f[i + 1] > L, c = f[i + gw + 1] > L, d = f[i + gw] > L;
    const k = (a ? 8 : 0) | (b ? 4 : 0) | (c ? 2 : 0) | (d ? 1 : 0); if (k === 0 || k === 15) continue;
    const T = 2 * i, Rt = 2 * (i + 1) + 1, B = 2 * (i + gw), Lf = 2 * i + 1;
    switch (k) {
      case 1: case 14: link(Lf, B); break; case 2: case 13: link(B, Rt); break; case 3: case 12: link(Lf, Rt); break;
      case 4: case 11: link(T, Rt); break; case 6: case 9: link(T, B); break; case 7: case 8: link(Lf, T); break;
      case 5: link(Lf, T); link(B, Rt); break; case 10: link(T, Rt); link(Lf, B); break;
    }
  }
  const loops = [], used = new Set();
  for (const start of segs.keys()) {
    if (used.has(start)) continue;
    const loop = []; let prev = -1, cur = start;
    while (cur !== undefined && !used.has(cur)) { used.add(cur); loop.push(P(cur)); const n = segs.get(cur); const nx = n[0] !== prev ? n[0] : n[1]; prev = cur; cur = nx; }
    if (loop.length > 3) loops.push(loop);
  }
  return loops;
}
function simplify(pts, eps) {   // Ramer–Douglas–Peucker on a closed loop
  if (pts.length < 4) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  const st = [[0, pts.length - 1]];
  while (st.length) { const [a, b] = st.pop(); let md = 0, mi = -1; const [ax, ay] = pts[a], [bx, by] = pts[b], dx = bx - ax, dy = by - ay, l = Math.hypot(dx, dy) || 1;
    for (let i = a + 1; i < b; i++) { const d = Math.abs((pts[i][0] - ax) * dy - (pts[i][1] - ay) * dx) / l; if (d > md) { md = d; mi = i; } }
    if (md > eps) { keep[mi] = 1; st.push([a, mi], [mi, b]); } }
  return pts.filter((_, i) => keep[i]);
}
const perim = p => { let s = 0; for (let i = 0; i < p.length; i++) { const a = p[i], b = p[(i + 1) % p.length]; s += Math.hypot(b[0] - a[0], b[1] - a[1]); } return s; };

/* ---------- inking ---------- */
function inkPath(x, pts, closed, w, color, wob) {
  x.strokeStyle = color; x.lineWidth = w; x.lineJoin = 'round'; x.lineCap = 'round';
  x.beginPath();
  const n = closed ? pts.length + 1 : pts.length;
  for (let i = 0; i < n; i++) {
    const [px, py] = pts[i % pts.length];
    if (i === 0) { x.moveTo(px, py); continue; }
    const [qx, qy] = pts[(i - 1) % pts.length], L = Math.hypot(px - qx, py - qy), m = Math.max(1, Math.round(L / 7));
    for (let s = 1; s <= m; s++) { const t = s / m, X = qx + (px - qx) * t, Y = qy + (py - qy) * t;
      x.lineTo(X + (vnoise(X * .09, Y * .09) - .5) * wob, Y + (vnoise(Y * .09 + 5, X * .09) - .5) * wob); }
  }
  x.stroke();
}
function textAlong(x, pts, closed, K, size, font, color, stream, gap = 0.25) {
  x.font = `${size}px ${font}`; x.fillStyle = color; x.textBaseline = 'middle'; x.textAlign = 'center';
  const segs = []; let tot = 0; const n = closed ? pts.length : pts.length - 1;
  for (let i = 0; i < n; i++) { const a = pts[i], b = pts[(i + 1) % pts.length], l = Math.hypot(b[0] - a[0], b[1] - a[1]); segs.push([a, b, l, tot]); tot += l; }
  if (tot < 20) return;
  const cw = {}; const w = ch => cw[ch] ?? (cw[ch] = x.measureText(ch).width);
  const str = stream(Math.ceil(tot / (size * 0.55)));
  let s = 2, si = 0;
  for (const ch of str) {
    const cwid = w(ch) + size * gap; if (s + cwid > tot - 2) break;
    const at = s + cwid / 2; while (si < segs.length - 1 && segs[si][3] + segs[si][2] < at) si++;
    const [a, b, l, o] = segs[si], t = (at - o) / (l || 1), px = a[0] + (b[0] - a[0]) * t, py = a[1] + (b[1] - a[1]) * t;
    let ang = Math.atan2(b[1] - a[1], b[0] - a[0]);
    const c = Math.cos(ang), sn = Math.sin(ang);
    x.setTransform(K * c, K * sn, -K * sn, K * c, K * px, K * py);
    if (ch !== ' ') x.fillText(ch, 0, 0);
    s += cwid;
  }
  x.setTransform(K, 0, 0, K, 0, 0);
}
function offsetLoop(loop, f, gw, C, d) {   // nudge points inward along the field gradient
  return loop.map(([px, py]) => {
    const gx = Math.min(gw - 2, Math.max(1, Math.round(px / C))), gy = Math.round(py / C), i = gy * gw + gx;
    let nx = (f[i + 1] ?? 0) - (f[i - 1] ?? 0), ny = (f[i + gw] ?? 0) - (f[i - gw] ?? 0); const l = Math.hypot(nx, ny) || 1;
    return [px + nx / l * d, py + ny / l * d];
  });
}

/* ---------- the build ---------- */
/* ======================================================================
   Live town: a fixed base field per town; every frame it is morphed (old→new town), pushed aside by
   windows (smooth displacement → blocks compress, alleys close, buildings merge), re-traced with
   marching squares and turned into glyph instances that the page draws on the GPU.
   ====================================================================== */
let G = { adv: null, A: null, B: null, gw: 0, gh: 0, C: 3, W: 0, H: 0 };
self.onmessage = e => {
  const m = e.data;
  if (m.paper) { const bitmap = buildPaper(m); self.postMessage({ paper: bitmap }, [bitmap]); return; }
  if (m.init) { G.adv = m.adv; G.nGlyph = m.adv.length; return; }
  if (m.town) { try { buildTown(m); } catch (err) { self.postMessage({ town: true, failed: String(err) }); } return; }
  if (m.frame) { try { frame(m); } catch (err) { self.postMessage({ frame: true, inst: new Float32Array(0), n: 0, failed: String(err) }); } return; }
  if (m.recycle) { if (m.recycle.length === 6 * 60000 && POOL.length < 3) POOL.push(m.recycle); return; }
};

// One world across displays: the town is laid out over the whole world (WW×WH, same seed on every display), but each
// display works out only its own part of it (W×H at OX, OY) plus a margin M, so its walls meet its neighbours' at the
// seams. FR: every display's frame in the world (null when alone). Grid cell (gx, gy) is world point (X0 + gx·C, Y0 + gy·C).
function onOneOf(FR, W, H, x0, y0, x1, y1) { return !FR ? x0 >= 0 && y0 >= 0 && x1 <= W && y1 <= H : FR.some(([fx, fy, fw, fh]) => x0 >= fx && y0 >= fy && x1 <= fx + fw && y1 <= fy + fh); }
function buildTown({ W, H, K, seed, t: tNow = 1, OX = 0, OY = 0, WW = W, WH = H, CX = W * .09, CY = H * .15, FR = null, E = null, paperSeed = 1, icons = [] }) {
  const R = rng(seed), C = 3, wins = icons,   // what the still parts must keep clear of: your desktop icons (towers, street names, marks)
   M = FR ? 160 : 0, X0 = Math.floor((OX - M) / C) * C, Y0 = Math.floor((OY - M) / C) * C;   // on the world's grid
  const onOne = (x0, y0, x1, y1) => onOneOf(FR, W, H, x0, y0, x1, y1);
  const t0 = performance.now();
  const gw = Math.ceil((OX + W + M - X0) / C) + 2, gh = Math.ceil((OY + H + M - Y0) / C) + 2, N = gw * gh;
  // roads (rasterised) → clearance distance
  const roads = makeRoads(WW, WH, R);
  const rings = [];
  for (let i = 0; i < 2; i++) {             // round towers with a circular road around them
    for (let tries = 0; tries < 30; tries++) {
      const r = 70 + R() * 70, cx = r + 40 + R() * (WW - 2 * r - 80), cy = r + 40 + R() * (WH - 2 * r - 80);
      if (FR && !onOne(cx - r - 30, cy - r - 30, cx + r + 30, cy + r + 50)) continue;      // a tower stands wholly on one display
      if (wins.some(w => cx + r > w.x - 60 && cx - r < w.x + w.w + 60 && cy + r > w.y - 60 && cy - r < w.y + w.h + 60)) continue;
      if (rings.some(o => Math.hypot(o.cx - cx, o.cy - cy) < o.r + r + 80)) continue;
      rings.push({ cx, cy, r });
      const pts = []; for (let a = 0; a <= 64; a++) pts.push([cx + Math.cos(a / 64 * Math.PI * 2) * (r + 18), cy + Math.sin(a / 64 * Math.PI * 2) * (r + 18)]);
      roads.push({ pts, width: 9, ring: true }); break;
    }
  }
  const seedMask = new Uint8Array(N), halfW = new Float32Array(N);
  for (const rd of roads) for (let i = 1; i < rd.pts.length; i++) {
    const [ax, ay] = rd.pts[i - 1], [bx, by] = rd.pts[i], L = Math.hypot(bx - ax, by - ay), m = Math.ceil(L / C);
    for (let s = 0; s <= m; s++) { const gx = Math.round((ax + (bx - ax) * s / m - X0) / C), gy = Math.round((ay + (by - ay) * s / m - Y0) / C);
      if (gx >= 0 && gy >= 0 && gx < gw && gy < gh) { const j = gy * gw + gx; seedMask[j] = 1; halfW[j] = Math.max(halfW[j], rd.width / 2); } }
  }
  const dRoad = distField(seedMask, gw, gh, C);
  // districts: each has its own street angle and lot size; their borders become streets
  const districts = [];
  const nd = Math.max(5, Math.round(WW * WH / (80000 + R() * 70000)));
  for (let i = 0; i < nd; i++) { const a = (R() - .5) * 1.6 + (R() < .3 ? Math.PI / 4 : 0), k = R();
    // dense lanes / ordinary streets / grand halls
    const [su, sv] = k < .3 ? [36 + R() * 30, 26 + R() * 14] : k < .8 ? [64 + R() * 60, 40 + R() * 28] : [120 + R() * 90, 70 + R() * 40];
    districts.push({ x: R() * WW, y: R() * WH, c: Math.cos(a), s: Math.sin(a), su, sv, id: i * 7919 }); }
  for (const rg of rings) if (R() < .85) {          // crescents of buildings curving round a tower
    const band = 60 + R() * 70; districts.push({ polar: true, x: rg.cx, y: rg.cy, r0: rg.r + 34, band, su: 40 + R() * 40, sv: 26 + R() * 18, id: 99991 + (rg.cx | 0) }); }
  const lotHash = (a, b, c) => h2(a * 0.137 + c * 0.71, b * 0.311 + c * 0.19);
  const f = new Float32Array(N);
  for (let gy = 0; gy < gh; gy++) for (let gx = 0; gx < gw; gx++) {
    const x = X0 + gx * C, y = Y0 + gy * C, i = gy * gw + gx;
    let d1 = 1e9, d2 = 1e9, D = null;
    for (const d of districts) {
      const dd = d.polar ? Math.max(0, Math.abs(Math.hypot(x - d.x, y - d.y) - d.r0 - d.band / 2) - d.band / 2) * 1.6 + 8 : Math.hypot(x - d.x, y - d.y);
      if (dd < d1) { d2 = d1; d1 = dd; D = d; } else if (dd < d2) d2 = dd; }
    // the district's own frame → staggered lots (brick bond); polar districts bend the rows into arcs
    let u0, v0;
    if (D.polar) { const dx = x - D.x, dy = y - D.y, rr = Math.hypot(dx, dy); v0 = rr - D.r0; u0 = (Math.atan2(dy, dx) + Math.PI) * (D.r0 + D.band / 2); }
    else { u0 = (x - D.x) * D.c + (y - D.y) * D.s; v0 = -(x - D.x) * D.s + (y - D.y) * D.c; }
    const row = Math.floor(v0 / D.sv), u = u0 + lotHash(row, 0, D.id) * D.su, col = Math.floor(u / D.su);
    const lu = u - col * D.su, lv = v0 - row * D.sv, hR = lotHash(row, col, D.id), hR2 = lotHash(col, row, D.id + 3), hR3 = lotHash(row + col, col - row, D.id + 5);
    const merged = hR < .38;                    // no alley to the next lot → long ranges of buildings
    const eU = merged ? 1e9 : Math.min(lu, D.su - lu) - (2.5 + hR2 * 2);
    const eV = Math.min(lv, D.sv - lv) - (3 + hR3 * 3);
    let v = Math.min(eU, eV);
    v = Math.min(v, (d2 - d1) * 0.5 - 7);      // streets between districts
    v = Math.min(v, dRoad[i] - 7);
    // carve notches / courtyards in the lot's frame → L, T, U, H shapes
    const lx = lu - D.su / 2, ly = lv - D.sv / 2;
    const box = (cx, cy, hw, hh) => { const qx = Math.abs(lx - cx) - hw, qy = Math.abs(ly - cy) - hh; return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0); };
    if (hR2 < .5) v = Math.min(v, box((hR - .5) * D.su * .6, hR2 < .25 ? -D.sv * .42 : D.sv * .42, 5 + hR3 * D.su * .12, D.sv * .22));
    if (hR3 > .7 && D.sv > 50) v = Math.min(v, box(0, 0, D.su * .16, D.sv * .14));
    if (hR > .86) v = Math.min(v, box(D.su * .3, 0, D.su * .12, D.sv));          // split into two
    // parks / open ground
    const pk = vnoise(x * .0036 + 9, y * .0036 + 4) * .7 + vnoise(x * .009 + 2, y * .009 + 7) * .3; if (pk < .3) v = Math.min(v, (pk - .3) * 420);   // smooth noise → clean park edges
    // keep clear of windows (the halls draw their own walls there) and of the round towers
    for (const rg of rings) v = Math.min(v, Math.hypot(x - rg.cx, y - rg.cy) - rg.r - 30);
    v = Math.min(v, Math.hypot(x - CX, y - CY) - 62);                            // compass rose
    f[i] = v;
  }
  // morph from the previous town (or from bare parchment)
  // morph from whatever is on screen right now (even mid-morph), or from bare parchment
  if (G.B && G.gw === gw && G.gh === gh && G.X0 === X0 && G.Y0 === Y0) {
    if (tNow < 1 && G.A) { const m = new Float32Array(N); for (let i = 0; i < N; i++) m[i] = G.A[i] + (G.B[i] - G.A[i]) * tNow; G.A = m; } else G.A = G.B;
  } else { G.A = new Float32Array(N).fill(-14); }
  G.B = f; G.gw = gw; G.gh = gh; G.W = W; G.H = H; G.C = C; G.X0 = X0; G.Y0 = Y0; G.gen = (G.gen || 0) + 1;
  if (!G.WOB || G.WOB.length !== N || G.wobAt !== X0 + ',' + Y0) {   // wavy court edges: noise baked once, looked up per frame
    G.WOB = new Float32Array(N); G.wobAt = X0 + ',' + Y0;
    for (let gy = 0; gy < gh; gy++) for (let gx = 0; gx < gw; gx++) G.WOB[gy * gw + gx] = (vnoise((X0 + gx * C) * .03, (Y0 + gy * C) * .03) - .5) * 18;
  }
  // the still parts of the plan: street names, round towers, little marks in open ground, ink splats
  const cv = new OffscreenCanvas(Math.round(W * K), Math.round(H * K)), x = cv.getContext('2d');
  // the parchment goes in first (painted afresh: the page keeps no copy of it between towns, ~24 MB saved per display)
  { const pb = buildPaper({ W, H, K, seed: paperSeed, OX, OY, WW, WH, E }); x.drawImage(pb, 0, 0, cv.width, cv.height); pb.close(); }
  x.setTransform(K, 0, 0, K, -OX * K, -OY * K);                       // drawn in world coordinates, shifted to this display
  const TR = rng(seed + 5), stream = textStream(TR);
  // street names along some roads
  const NR = rng(seed + 9), labelled = [];
  for (const rd of roads) {
    if (rd.ring || rd.pts.length < 30 || NR() < .35) continue;
    const st = Math.floor(rd.pts.length * (.2 + NR() * .3)), seg = rd.pts.slice(st, st + 26);
    { let a0 = 1e9, b0 = 1e9, a1 = -1e9, b1 = -1e9; for (const [px, py] of seg) { a0 = Math.min(a0, px); b0 = Math.min(b0, py); a1 = Math.max(a1, px); b1 = Math.max(b1, py); }
      if (!onOne(a0 - 10, b0 - 10, a1 + 10, b1 + 10)) continue; }        // a street's name stays on one display
    const mid0 = seg[13]; if (labelled.some(([lx, ly]) => Math.hypot(lx - mid0[0], ly - mid0[1]) < 180)) continue;
    if (wins.some(w => mid0[0] > w.x - 40 && mid0[0] < w.x + w.w + 40 && mid0[1] > w.y - 40 && mid0[1] < w.y + w.h + 40)) continue;
    labelled.push(mid0);
    let s2 = seg; if (s2[s2.length - 1][0] < s2[0][0]) s2 = s2.slice().reverse();      // keep it readable
    const name = streetName(NR); textAlong(x, s2, false, K, 10, SCRIPT, INK, () => name, .02);
  }
  // round towers: text band + radial stair + inner court with a title
  for (const rg of rings) drawRing(x, rg, K, stream, rng(seed + rg.cx | 0));
  // open-ground details: little wheels, trees, scribbles, footpaths
  // each mark has its own dice (so every display draws the same marks, whichever it can check)
  for (let n = 0; n < WW * WH / 9000; n++) {
    const DR = rng(seed * 31 + n * 7919 + 13), px = DR() * WW, py = DR() * WH, gx = Math.round((px - X0) / C), gy = Math.round((py - Y0) / C);
    if (gx < 0 || gy < 0 || gx >= gw || gy >= gh) continue;
    const gi = gy * gw + gx;
    if (!(f[gi] < -14) || dRoad[gi] < 14) continue;
    if (wins.some(w => px > w.x - 34 && px < w.x + w.w + 34 && py > w.y - 34 && py < w.y + w.h + 34)) continue;
    const k = DR();
    if (k < .5) { x.strokeStyle = INK_SOFT; x.lineWidth = .6; x.beginPath(); let qx = px, qy = py; x.moveTo(qx, qy);
      for (let s = 0; s < 14; s++) { qx += 3 + DR() * 2; qy += Math.sin(s * 1.6 + px) * 2; x.lineTo(qx, qy); } x.stroke(); }
    else if (k < .62) { x.strokeStyle = INK; x.lineWidth = .7; x.beginPath(); x.arc(px, py, 6, 0, 7); x.stroke();
      x.beginPath(); for (let s = 0; s < 8; s++) { const a = s * Math.PI / 4; x.moveTo(px, py); x.lineTo(px + Math.cos(a) * 6, py + Math.sin(a) * 6); } x.stroke(); }
    else if (k < .8) { x.strokeStyle = INK; x.lineWidth = .6; x.beginPath();
      for (let s = 0; s <= 18; s++) { const a = s / 18 * Math.PI * 2, rr = 5 * (.8 + .25 * Math.sin(a * 5 + px)); s ? x.lineTo(px + Math.cos(a) * rr, py + Math.sin(a) * rr) : x.moveTo(px + rr, py); } x.stroke(); }
    else { x.fillStyle = INK_SOFT; x.beginPath(); x.arc(px, py, .9, 0, 7); x.fill(); }
  }
  const SR = rng(seed + 21);
  for (let n = 0; n < (2 + Math.floor(SR() * 3)) * (FR ? FR.length : 1); n++) splat(x, 60 + SR() * (WW - 120), 60 + SR() * (WH - 120), 6 + SR() * 12, SR);
  const spots = [], PR = rng(seed + 31 + Math.round(OX) * 7 + Math.round(OY) * 13);   // each display its own label spots
  for (let k = 0; k < 900 && spots.length < 160; k++) {
    const px = OX + 60 + PR() * (W - 120), py = OY + 40 + PR() * (H - 80), gi = Math.round((py - Y0) / C) * gw + Math.round((px - X0) / C);   // this display's own open ground
    if (f[gi] < -22 && dRoad[gi] > 14 && !rings.some(rg => Math.hypot(px - rg.cx, py - rg.cy) < rg.r + 50)) spots.push([px - OX, py - OY, -f[gi]]);
  }
  spots.sort((a, b) => b[2] - a[2]);
  const bitmap = cv.transferToImageBitmap();
  self.postMessage({ town: true, gen: G.gen, bitmap, spots, roads: roads.filter(r => !r.ring).map(r => r.pts.filter((_, i) => i % 3 === 0)), rings,
    ms: Math.round(performance.now() - t0) }, [bitmap]);
}

/* ---------- one animation frame ---------- */
let F = null, LK = null, TOUCH = null, VIS = null, INST = new Float32Array(6 * 60000);
const POOL = [];        // instance buffers ping-pong with the page (no per-frame 1.4 MB allocations)
function sampleBase(x, y, t) {
  const { gw, gh, C, A, B } = G;
  const fx = Math.min(Math.max(x / C, 0), gw - 1.001), fy = Math.min(Math.max(y / C, 0), gh - 1.001);
  const ix = fx | 0, iy = fy | 0, tx = fx - ix, ty = fy - iy, i = iy * gw + ix;
  const b = (B[i] * (1 - tx) + B[i + 1] * tx) * (1 - ty) + (B[i + gw] * (1 - tx) + B[i + gw + 1] * tx) * ty;
  if (t >= 1) return b;
  const a = (A[i] * (1 - tx) + A[i + 1] * tx) * (1 - ty) + (A[i + gw] * (1 - tx) + A[i + gw + 1] * tx) * ty;
  return a + (b - a) * t;
}
let e_sent = 0;
function frame({ wins, t, sent, gen }) {
  e_sent = sent;
  if (gen !== undefined && gen !== G.gen) t = 0;      // the page hasn't seen this town yet: show where it starts
  if (!G.B || !G.adv) return self.postMessage({ frame: true, inst: new Float32Array(0), n: 0 });
  const t0 = performance.now(), { gw, gh, C, A, B, X0 = 0, Y0 = 0 } = G, N = gw * gh;
  if (!F || F.length !== N) F = new Float32Array(N);
  // base (morphing between towns)
  if (t >= 1) F.set(B); else for (let i = 0; i < N; i++) F[i] = A[i] + (B[i] - A[i]) * t;
  // windows: a wavy court cut around each. The cut-out field is cached and rebuilt only when a window
  // actually moved or faded; each window touches only its own neighbourhood (not the union of all).
  const key = wins.map(w => `${w.x.toFixed(1)},${w.y.toFixed(1)},${w.w.toFixed(1)},${w.h.toFixed(1)},${w.life.toFixed(3)}`).join(';');
  if (key !== G.cutKey || !G.CUT || G.CUT.length !== N) {
    if (!G.CUT || G.CUT.length !== N) { G.CUT = new Float32Array(N).fill(1e9); G.cutBox = null; }
    const CUT = G.CUT;
    if (G.cutBox) { const [a0, a1, b0, b1] = G.cutBox; for (let gy = b0; gy <= b1; gy++) CUT.fill(1e9, gy * gw + a0, gy * gw + a1 + 1); }
    let bx0 = gw, bx1 = -1, by0 = gh, by1 = -1;          // the cells this pass touched (not the world offsets X0/Y0)
    for (const w of wins) {
      if (w.life <= .002) continue;
      const hw = w.w / 2, hh = w.h / 2, L = w.life, m = (w.w * w.h < 60000 ? 8 : 18), cx = w.x + hw, cy = w.y + hh;
      const reach = Math.max(hw, hh) + m + 30, shrink = (1 - L) * Math.min(hw, hh) * 1.3 - m * L;
      const x0 = Math.max(0, Math.floor((cx - hw - m - 30 - X0) / C)), x1 = Math.min(gw - 1, Math.ceil((cx + hw + m + 30 - X0) / C));
      const y0 = Math.max(0, Math.floor((cy - hh - m - 30 - Y0) / C)), y1 = Math.min(gh - 1, Math.ceil((cy + hh + m + 30 - Y0) / C));
      if (x0 > x1 || y0 > y1) continue;
      bx0 = Math.min(bx0, x0); bx1 = Math.max(bx1, x1); by0 = Math.min(by0, y0); by1 = Math.max(by1, y1);
      for (let gy = y0; gy <= y1; gy++) { const ay = Math.abs(Y0 + gy * C - cy) - hh, row = gy * gw;
        for (let gx = x0; gx <= x1; gx++) {
          const ax = Math.abs(X0 + gx * C - cx) - hw, ox = ax > 0 ? ax : 0, oy = ay > 0 ? ay : 0;
          const d = Math.sqrt(ox * ox + oy * oy) + Math.min(Math.max(ax, ay), 0);
          const v = d + G.WOB[row + gx] * L + shrink, i = row + gx;
          if (v < CUT[i]) CUT[i] = v;
        } }
    }
    G.cutBox = bx1 >= 0 ? [bx0, bx1, by0, by1] : null; G.cutKey = key;
  }
  if (G.cutBox) { const [a0, a1, b0, b1] = G.cutBox, CUT = G.CUT;
    for (let gy = b0; gy <= b1; gy++) for (let i = gy * gw + a0, e = gy * gw + a1; i <= e; i++) if (CUT[i] < F[i]) F[i] = CUT[i]; }
  const tA = performance.now();
  INST = POOL.length ? POOL.pop() : new Float32Array(6 * 60000);    // a buffer we own (the last one went to the page)
  // trace the wall centre-lines and lay letters along them
  const loops = traceLoops(F, gw, gh, C, 2.5);
  const tB = performance.now();
  let n = 0;
  for (let loop of loops) {
    loop = simplify(loop, .7); if (X0 || Y0) loop = loop.map(([x, y]) => [x + X0, y + Y0]);   // world coordinates: letters hash where they land on the map
    const per = perim(loop); if (per < 60) continue;
    // canonical start (top-most point) + orientation, so letters stay put while nothing moves
    let si = 0; for (let i = 1; i < loop.length; i++) if (loop[i][1] < loop[si][1] - .01 || (Math.abs(loop[i][1] - loop[si][1]) <= .01 && loop[i][0] < loop[si][0])) si = i;
    loop = loop.slice(si).concat(loop.slice(0, si));
    let ar = 0; for (let i = 0; i < loop.length; i++) { const p = loop[i], q = loop[(i + 1) % loop.length]; ar += p[0] * q[1] - q[0] * p[1]; }
    if (ar < 0) loop = [loop[0]].concat(loop.slice(1).reverse());
    const alpha = Math.min(1, Math.max(0, (per - 60) / 90)) * .9;
    n = layLetters(loop, 4.6, alpha, n);
    if (n > 59000) break;
  }
  const out = INST, tC = performance.now();
  self.postMessage({ frame: true, inst: out, n, sent: e_sent, ms: Math.round(tC - t0), split: `field ${(tA - t0).toFixed(1)} trace ${(tB - tA).toFixed(1)} letters ${(tC - tB).toFixed(1)} loops ${loops.length} glyphs ${n}` }, [out.buffer]);
}
// letters sit at world-fixed spots along each wall segment (multiples of the spacing, measured along the
// wall's own direction), and which letter goes there is hashed from that spot — so unchanged walls keep
// identical letters every frame, and only walls that really move get rewritten.
const lhash = (a, b, c) => { let h = Math.imul(a | 0, 374761393) ^ Math.imul(b | 0, 668265263) ^ Math.imul(c | 0, 2246822519); h = Math.imul(h ^ h >>> 13, 1274126177); return ((h ^ h >>> 16) >>> 0) / 4294967296; };
function layLetters(loop, size, alpha, n) {
  // continuous along the wall from the loop's canonical (top-most) start, so spacing is even round
  // corners and curves; each letter is picked by hashing where it lands on the map
  const NG = G.nGlyph, sp = size * .74, L = loop.length;
  let carry = sp * .5;
  for (let i = 0; i < L; i++) {
    const a = loop[i], b = loop[(i + 1) % L], dx = b[0] - a[0], dy = b[1] - a[1], len = Math.hypot(dx, dy);
    if (len < 1e-3) continue;
    const ux = dx / len, uy = dy / len, ang = Math.atan2(uy, ux);
    let t = carry;
    for (; t < len; t += sp) {
      const px = a[0] + ux * t, py = a[1] + uy * t, qx = Math.round(px / 3), qy = Math.round(py / 3);
      if (lhash(qx, qy, 11) < .12) continue;             // gaps between words
      const o = n * 6; INST[o] = px; INST[o + 1] = py; INST[o + 2] = ang;
      INST[o + 3] = Math.floor(lhash(qx, qy, 5) * NG); INST[o + 4] = alpha; INST[o + 5] = size; n++;
      if (n > 59990) return n;
    }
    carry = t - len;
  }
  return n;
}
// marching squares with typed arrays (no Maps): chains segments into closed loops
function traceLoops(f, gw, gh, C, L) {
  const E = 2 * gw * gh;
  if (!LK || LK.length !== E * 2) { LK = new Int32Array(E * 2).fill(-1); TOUCH = new Int32Array(E); VIS = new Uint8Array(E); }
  let nt = 0;
  const link = (a, b) => {
    if (LK[2 * a] === -1) { LK[2 * a] = b; TOUCH[nt++] = a; } else LK[2 * a + 1] = b;
    if (LK[2 * b] === -1) { LK[2 * b] = a; TOUCH[nt++] = b; } else LK[2 * b + 1] = a;
  };
  for (let y = 0; y < gh - 1; y++) for (let x = 0; x < gw - 1; x++) {
    const i = y * gw + x, k = (f[i] > L ? 8 : 0) | (f[i + 1] > L ? 4 : 0) | (f[i + gw + 1] > L ? 2 : 0) | (f[i + gw] > L ? 1 : 0);
    if (k === 0 || k === 15) continue;
    const T = 2 * i, Rt = 2 * (i + 1) + 1, B = 2 * (i + gw), Lf = 2 * i + 1;
    switch (k) {
      case 1: case 14: link(Lf, B); break; case 2: case 13: link(B, Rt); break; case 3: case 12: link(Lf, Rt); break;
      case 4: case 11: link(T, Rt); break; case 6: case 9: link(T, B); break; case 7: case 8: link(Lf, T); break;
      case 5: link(Lf, T); link(B, Rt); break; case 10: link(T, Rt); link(Lf, B); break;
    }
  }
  const P = id => { const cell = id >> 1, x = cell % gw, y = (cell / gw) | 0;
    if ((id & 1) === 0) { const a = f[cell] - L, b = f[cell + 1] - L; return [(x + a / (a - b)) * C, y * C]; }
    const a = f[cell] - L, b = f[cell + gw] - L; return [x * C, (y + a / (a - b)) * C]; };
  const loops = [];
  for (let k = 0; k < nt; k++) {
    const start = TOUCH[k]; if (VIS[start]) continue;
    const loop = []; let prev = -1, cur = start;
    while (cur !== -1 && !VIS[cur]) { VIS[cur] = 1; loop.push(P(cur)); const a = LK[2 * cur], b = LK[2 * cur + 1], nx = a !== prev ? a : b; prev = cur; cur = nx; }
    if (loop.length > 3) loops.push(loop);
  }
  for (let k = 0; k < nt; k++) { const e = TOUCH[k]; LK[2 * e] = LK[2 * e + 1] = -1; VIS[e] = 0; }
  return loops;
}

const ST_A = ['Lower', 'Upper', 'North', 'East', 'West', 'South', 'Old', 'Long', 'Crooked', 'Quiet', 'Narrow', 'Grey', 'Lantern', 'Hidden'];
const ST_B = ['Corridor', 'Passage', 'Walk', 'Stair', 'Row', 'Lane', 'Gallery', 'Way', 'Cloister', 'Arcade'];
const ST_C = ['', '', ' North-East', ' of Echoes', ' to the Kitchens', ' (Keep Left)', ' of Lost Keys', ' Below', ' Beyond'];
function streetName(R) { return `${ST_A[Math.floor(R() * ST_A.length)]} ${ST_B[Math.floor(R() * ST_B.length)]}${ST_C[Math.floor(R() * ST_C.length)]}`; }
function drawRing(x, { cx, cy, r }, K, stream, R) {
  const circ = (rr, n = 90) => { const p = []; for (let i = 0; i < n; i++) { const a = i / n * Math.PI * 2; p.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr]); } return p; };
  x.fillStyle = 'rgba(238,224,192,.6)'; x.beginPath(); x.arc(cx, cy, r, 0, 7); x.fill();
  inkPath(x, circ(r), true, 1, INK, .7); inkPath(x, circ(r - 8), true, .7, INK, .6);
  textAlong(x, circ(r - 4, 140), true, K, 6, SERIF, INK_SOFT, stream, .1);
  // radial stair band
  x.strokeStyle = INK; x.lineWidth = .55; x.beginPath();
  const n = Math.round(r * 1.1); for (let i = 0; i < n; i++) { const a = i / n * Math.PI * 2; x.moveTo(cx + Math.cos(a) * (r - 10), cy + Math.sin(a) * (r - 10)); x.lineTo(cx + Math.cos(a) * (r - 26), cy + Math.sin(a) * (r - 26)); }
  x.stroke();
  inkPath(x, circ(r - 27), true, .8, INK, .6); inkPath(x, circ(r * .5), true, .9, INK, .6);
  textAlong(x, circ(r * .5 + 4, 120), true, K, 5.5, SERIF, INK_SOFT, stream, .1);
  const words = ['TVRRIS', 'MAGNA', 'ARX', 'NOVA', 'STELLA', 'VETVS', 'ALTA', 'LVCIS', 'VMBRA', 'DOMVS'];
  x.fillStyle = INK; x.font = `${Math.max(9, r * .14)}px ${SERIF}`; x.textAlign = 'center'; x.textBaseline = 'middle';
  const a = words[Math.floor(R() * words.length)], b = words[Math.floor(R() * words.length)];
  x.fillText(a.split('').join(' '), cx, cy - r * .1); x.fillText(b.split('').join(' '), cx, cy + r * .12);
}

function splat(x, cx, cy, r, R) {   // an ink blot with droplets and a short flick
  x.fillStyle = 'rgba(70,44,26,0.5)';
  x.beginPath();
  for (let i = 0; i <= 40; i++) { const a = i / 40 * Math.PI * 2, rr = r * (.75 + .5 * vnoise(Math.cos(a) * 1.7 + cx, Math.sin(a) * 1.7 + cy) + (R() < .08 ? R() * .5 : 0));
    i ? x.lineTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr) : x.moveTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr); }
  x.fill();
  for (let i = 0; i < 10 + R() * 14; i++) { const a = R() * 7, d = r * (1.2 + R() * 2.6), s = .5 + R() * r * .16;
    x.beginPath(); x.arc(cx + Math.cos(a) * d, cy + Math.sin(a) * d, s, 0, 7); x.fill(); }
  const a = R() * 7; x.lineCap = 'round'; x.strokeStyle = 'rgba(70,44,26,0.42)';
  for (let k = 0; k < 3; k++) { x.lineWidth = 2.4 - k * .7; x.beginPath(); x.moveTo(cx + Math.cos(a) * r * .8, cy + Math.sin(a) * r * .8);
    x.quadraticCurveTo(cx + Math.cos(a + .2) * r * 2, cy + Math.sin(a + .2) * r * 2, cx + Math.cos(a + .1) * r * (2.6 + k), cy + Math.sin(a + .1) * r * (2.6 + k)); x.stroke(); }
}

/* ---------- old parchment (built here too, so the page never stalls) ---------- */
function ridge(x, y) { return 1 - Math.abs(vnoise(x, y) * 2 - 1); }
function buildPaper({ W, H, K, seed, OX = 0, OY = 0, WW = W, WH = H, E = null }) {
  const R = rng(seed + 77), S = 2, sw = Math.ceil(W / S), sh = Math.ceil(H / S);
  // how far inside the sheet: to the world's outside edges (E: segments), else to this display's own edges
  const edgeD = (X, Y) => { if (!E) return Math.min(X, Y, W - X, H - Y); let d = 1e9; for (const [ax, ay, bx, by] of E) { const px = X - ax, py = Y - ay, vx = bx - ax, vy = by - ay, h = Math.max(0, Math.min(1, (px * vx + py * vy) / (vx * vx + vy * vy || 1))); d = Math.min(d, Math.hypot(px - vx * h, py - vy * h)); } return d; };
  const small = new OffscreenCanvas(sw, sh), sx = small.getContext('2d'), img = sx.createImageData(sw, sh), d = img.data;
  const ox = R() * 100, oy = R() * 100;
  for (let j = 0; j < sh; j++) for (let i = 0; i < sw; i++) {
    const X = i * S + OX, Y = j * S + OY;
    // base: warm tan, lighter towards the middle, mottled
    const mott = fbm(X * .004 + ox, Y * .004 + oy), mott2 = fbm(X * .02 + 11, Y * .02 + 5);
    // crumple: a network of creases (ridged noise at two scales), lit from the top-left
    const c1 = Math.pow(ridge(X * .005 + ox, Y * .005), 22), c2 = Math.pow(ridge(X * .013 + 3, Y * .013 + oy), 26) * .6;
    const c1b = Math.pow(ridge(X * .005 + ox + .02, Y * .005 + .02), 22), c2b = Math.pow(ridge(X * .013 + 3.03, Y * .013 + oy + .03), 26) * .6;
    const crease = (c1 + c2) * 13 - (c1b + c2b) * 9;
    // burnt, darkened edges with a ragged boundary
    const e = edgeD(X, Y) / (E ? 1000 : Math.min(W, H)) + (fbm(X * .01 + 50, Y * .01) - .5) * .07;   // (a world: one burn width everywhere)
    const burn = Math.max(0, 1 - e / .2), burn2 = burn * burn;
    let r = 232 - 30 * mott - 10 * mott2, g = 212 - 40 * mott - 12 * mott2, b = 170 - 52 * mott - 14 * mott2;
    r += crease; g += crease * .92; b += crease * .8;
    r = r * (1 - .55 * burn2) + 70 * .55 * burn2; g = g * (1 - .62 * burn2) + 40 * .62 * burn2; b = b * (1 - .7 * burn2) + 18 * .7 * burn2;
    const grain = (h2(X, Y) - .5) * 10; const o = (j * sw + i) * 4;
    d[o] = r + grain; d[o + 1] = g + grain; d[o + 2] = b + grain * .8; d[o + 3] = 255;
  }
  sx.putImageData(img, 0, 0);
  const cv = new OffscreenCanvas(Math.round(W * K), Math.round(H * K)), x = cv.getContext('2d');
  x.imageSmoothingQuality = 'high'; x.drawImage(small, 0, 0, cv.width, cv.height); x.setTransform(K, 0, 0, K, -OX * K, -OY * K);
  // fine fibre grain at full resolution
  const t = new OffscreenCanvas(128, 128), tx = t.getContext('2d'), ti = tx.createImageData(128, 128);
  for (let i = 0; i < ti.data.length; i += 4) { const v = R(); ti.data[i] = ti.data[i + 1] = ti.data[i + 2] = v < .5 ? 60 : 255; ti.data[i + 3] = 10 + v * 14; }
  tx.putImageData(ti, 0, 0); x.fillStyle = x.createPattern(t, 'repeat'); x.fillRect(OX, OY, W, H);
  // stains: big soft blotches, water rings, a coffee ring
  x.globalCompositeOperation = 'multiply';
  const many = E ? WW * WH / 1.5e6 : 1;                                   // a world: as many stains as its size calls for, the same count on every display
  for (let i = 0; i < Math.round(9 * many); i++) { const px = R() * WW, py = R() * WH, r = 40 + R() * 160, g = x.createRadialGradient(px, py, 0, px, py, r);
    g.addColorStop(0, `rgba(170,120,70,${.06 + R() * .1})`); g.addColorStop(.7, `rgba(170,120,70,${.05 + R() * .06})`); g.addColorStop(1, 'rgba(170,120,70,0)');
    x.fillStyle = g; x.beginPath(); x.arc(px, py, r, 0, 7); x.fill(); }
  for (let i = 0; i < Math.round(3 * many); i++) { const px = R() * WW, py = R() * WH, r = 24 + R() * 50;
    x.strokeStyle = `rgba(140,90,45,${.12 + R() * .12})`;
    for (let k = 0; k < 3; k++) { x.lineWidth = 1.6 - k * .4; x.beginPath(); x.arc(px + k, py - k * .5, r - k * 1.5, R() * 1.5, Math.PI * (1.5 + R() * .5)); x.stroke(); } }
  for (let i = 0; i < WW * WH / 6000; i++) { const px = R() * WW, py = R() * WH, r = R() < .92 ? .6 + R() * 2.4 : 4 + R() * 9;   // foxing
    const g = x.createRadialGradient(px, py, 0, px, py, r); g.addColorStop(0, `rgba(120,70,30,${.12 + R() * .2})`); g.addColorStop(1, 'rgba(120,70,30,0)');
    x.fillStyle = g; x.beginPath(); x.arc(px, py, r, 0, 7); x.fill(); }
  x.globalCompositeOperation = 'source-over';
  return cv.transferToImageBitmap();
}
