// Runs in every wallpaper page after the page's own scripts. Pages built on the shared morph (commit, refresh, FB):
// while a window is dragged (window.__live) a change snaps the field instead of restarting the morph, and a morph
// asks for the full frame rate until it ends (the calm rate, 12 fps on Ink Map, is for a scene at rest; a settling
// island drawn at it steps visibly, and a drag's own boost ends 0.9 s after the window stops while the morph doesn't).
(() => {
  if (!window.__gl) return;
  window.__live = false;
  const commit0 = commit;
  const settle = () => { if (window.__twSettle) window.__twSettle((typeof morphDur === 'number' ? morphDur : 1500) + 250); };
  commit = function (fromEmpty) {
    if (window.__live && !fromEmpty && FB) { refresh(); return; }
    settle();
    return commit0(fromEmpty);
  };
  webkit.messageHandlers.host.postMessage('patched');
})();
