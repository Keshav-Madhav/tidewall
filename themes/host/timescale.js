// Filming in slow motion (--timescale k): every clock the page can read runs k times slower, so frames can be taken
// at a pace that plays back smoothly at real speed.
(k => {
  const now = performance.now.bind(performance), t0 = now();
  performance.now = () => t0 + (now() - t0) * k;
  const dateNow = Date.now, d0 = dateNow();
  Date.now = () => d0 + (dateNow() - d0) * k;
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = cb => raf(t => cb(t0 + (t - t0) * k));
  const setTimeout0 = window.setTimeout.bind(window), setInterval0 = window.setInterval.bind(window);
  window.setTimeout = (f, d, ...rest) => setTimeout0(f, (d || 0) / k, ...rest);
  window.setInterval = (f, d, ...rest) => setInterval0(f, (d || 0) / k, ...rest);
  const slowAnimations = () => {
    try { for (const a of document.getAnimations()) if (a.playbackRate !== k) a.playbackRate = k; } catch (_) {}
    raf(slowAnimations);
  };
  raf(slowAnimations);
})
