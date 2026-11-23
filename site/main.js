// The page around the live wall (mounted first thing, in index.html, so the map is drawing while the rest loads).
const WALLS = [
  ['inkmap', 'Ink Map', 'very low', 'A pen-and-ink archipelago: every window becomes an island, and a little boat sails to your cursor.'],
  ['railway', 'Model Railway', 'very low', 'A toy railway diorama: windows become towns, and trains run between them.'],
  ['garden', 'Garden Plan', 'very low', "A landscape architect's planting plan: windows become flowerbeds and gardeners tend the paths."],
  ['estate', 'Marauders', 'very low', 'An enchanted castle plan on parchment; footprints follow your cursor.'],
  ['gallery', 'Gallery', 'none', 'A museum wall: every window hangs in a real frame, among public-domain masterpieces.'],
  ['celestial', 'Celestial Atlas', 'none', "Tonight's real sky over your city, as an antique star chart. Windows are black holes."],
  ['snow', 'Snowfall', 'low', 'A painted moonlit valley. Snow settles on the tops of your windows.'],
  ['lava', 'Lava Lamp', 'low', 'Soft-body wax with real buoyancy, heat and coalescence, in nine colourways.'],
  ['wind', 'Wind Map', 'medium', 'Live surface wind over your country, on hand-inked relief that follows day and night.'],
  ['reef', 'Koi Reef', 'medium', 'A sunlit lagoon that grows and recedes around your windows; koi and reef fish.'],
  ['beach', 'Beach', 'medium', 'Painted sand and a turquoise sea that laps around your windows.'],
  ['meadow', 'Meadow', 'high', 'A painted meadow that parts around your windows.'],
  ['tunnel', 'Wind Tunnel', 'high', 'A real fluid simulation: smoke streams past museum-scanned models and around your windows.'],
];
const strip = document.getElementById('strip');
for (const [id, name, cost, line] of WALLS) {
  const f = document.createElement('figure');
  const img = new Image();
  img.src = `shots/${id}.jpg`; img.alt = `${name}, with two windows on it`; img.loading = 'lazy'; img.decoding = 'async';
  const cap = document.createElement('figcaption');
  const top = document.createElement('div'); top.className = 'name';
  const n = document.createElement('b'); n.textContent = name;
  const c = document.createElement('span'); c.textContent = id === 'inkmap' ? 'behind this page' : `${cost} cost`;
  top.append(n, c);
  const p = document.createElement('p'); p.textContent = line;
  cap.append(top, p); f.append(img, cap); strip.append(f);
}
const step = dir => strip.scrollBy({ left: dir * (strip.firstElementChild.getBoundingClientRect().width + 18), behavior: 'smooth' });
document.getElementById('prev').addEventListener('click', () => step(-1));
document.getElementById('next').addEventListener('click', () => step(1));
strip.addEventListener('keydown', e => {
  if (e.key === 'ArrowRight') { e.preventDefault(); step(1); }
  if (e.key === 'ArrowLeft') { e.preventDefault(); step(-1); }
});

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const narrow = innerWidth < 760;
const wall = window.tide;
if (reduce) { let t; addEventListener('scroll', () => { clearTimeout(t); t = setTimeout(() => wall.update(false), 200); }, { passive: true }); }

// the hero panel is a window you can move (on a phone it would trap the scroll, so there it rides the page)
const head = document.getElementById('head'), hint = document.getElementById('hint');
if (!narrow) {
  const r = head.getBoundingClientRect(), hero = head.parentElement.getBoundingClientRect();
  head.style.top = (r.top - hero.top) + 'px'; head.style.transform = 'none';   // (centred with a transform: fix it in pixels)
  TW.draggable(head, {
    within: head.parentElement,
    onStart: () => { hint.style.opacity = 0; },
    onMove: () => wall.update(true), onDrop: () => wall.update(false),
  });
}
// the panels below are windows too: moved by their grip (so the film's controls and the walls' strip still work as
// they look); a double-click on the grip puts one back
if (!narrow) for (const id of ['film', 'walls', 'perf', 'end']) {
  const el = document.getElementById(id);
  const d = TW.draggable(el, { within: document.body, handle: '.grip', onMove: () => wall.update(true), onDrop: () => wall.update(false) });
  el.style.touchAction = '';                                         // (only the grip takes the pointer: the page still scrolls)
  el.querySelector('.grip').addEventListener('dblclick', () => { d.moveTo(0, 0); wall.update(false); });
}
wall.update(false);   // the page has laid out: tell the map where its panels are

// the film plays only while you can see it
const video = document.getElementById('video');
if (!reduce) new IntersectionObserver(([e]) => { if (e.isIntersecting) video.play().catch(() => {}); else video.pause(); }, { threshold: 0.4 }).observe(video);

// the Download button in the corner hands over the file for this computer: the Mac app by default, the Windows
// installer on Windows (the Arm one where the browser says so; the x64 one runs on Arm too, emulated)
{
  const get = document.getElementById('get'), base = 'https://github.com/Keshav-Madhav/tidewall/releases/latest/download/';
  const ua = navigator.userAgentData, win = ua ? ua.platform === 'Windows' : /Windows/.test(navigator.userAgent);
  if (get && win) {
    get.href = base + 'Tidewall-win-x64-Setup.exe';
    if (ua && ua.getHighEntropyValues) ua.getHighEntropyValues(['architecture']).then(v => { if (v.architecture === 'arm') get.href = base + 'Tidewall-win-arm64-Setup.exe'; }).catch(() => {});
  }
}
