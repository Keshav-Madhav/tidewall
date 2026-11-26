#!/bin/bash
# The regression suite: run it before every release (tools/release.sh does, and refuses to tag if it fails).
#
#   tools/regress.sh [--quick] [--update-visuals] [<output dir>]
#
#   solo:   every wall alone on this Mac's main display, with nine pretend desktop icons
#   world:  every wall that spans displays, across three pretend displays; each display's picture is checked
#           (tools/visual-check.py: a blank wall fails, one unlike its reference asks for a look) and laid out on
#           one contact sheet, <output dir>/sheet.jpg, to look at before releasing
#   smooth: every wall's frame rate through a window move and its settle, and back at rest (tools/smooth.sh): a wall
#           that got less smooth, or stays boosted, fails. Needs the Mac plugged in, Low Power Mode off
#   stress: 95 s of the Settings window clicked through as fast as a person can, with the malloc guards on
#   --quick runs solo only (about 3 minutes); the whole suite takes about 15.
#
# Fails on: a wall drawing below the screen's resolution, a wall less smooth than its reference (or no measurement: on battery), a JavaScript error (the weather service being busy or out of quota doesn't count; it's listed apart), a
# crash, a page that never got ready, or a blank wall. Needs a logged-in session (the walls are real windows) and
# Python with Pillow for the pictures (skipped, with a warning, without it). Every test window sits behind your
# wallpaper (--behind), and the Settings window is never brought forward: you can keep working while it runs.
set -uo pipefail
cd "$(dirname "$0")/.."
quick=0; upd=""; out=""; TH="${TIDEWALL_REGRESS_THEMES:-$PWD/themes}"   # (tests of the suite itself point it at broken copies)
for a in "$@"; do case "$a" in --quick) quick=1;; --update-visuals) upd=--update;; *) out="$a";; esac; done
out="${out:-${TMPDIR:-/tmp}/tidewall-regress-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$out"
PY=""; for p in python3 /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /opt/homebrew/bin/python3; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import PIL' 2>/dev/null; then PY="$p"; break; fi; done

echo "building (development build)…"
tools/dev-build.sh > "$out/build.log" 2>&1 \
  || { echo "✗ the build failed:"; grep -m5 "error" "$out/build.log"; exit 1; }
rm -f "$out"/w-* "$out"/solo-* "$out"/stress.log "$out"/sheet.jpg   # (an old run's pictures must never stand in for this one's)
bash tools/check-pages.sh >/dev/null || { echo "✗ a page doesn't parse (tools/check-pages.sh)"; exit 1; }
# every wall that animates a layout change says so while it settles (window.__twSettle: the full frame rate until it
# has; the smoothness check verifies the rate, this that the call is still there)
for f in inkmap flat meadow garden estate railway; do grep -q "__twSettle" "$TH/$f.html" || { echo "✗ $f.html no longer calls __twSettle while it settles: its transitions would drop to the calm rate"; exit 1; }; done
grep -q "window.__twSettle((typeof morphDur" themes/host/late.js || { echo "✗ themes/host/late.js: commit() no longer asks for the full rate during a morph"; exit 1; }

# the weather service (Wind Map's two calls) being busy or out of its daily quota isn't a Tidewall fault: only those
# call sites' errors are excused, nothing else that merely mentions a fetch
NET='JSERR (wind fetch|wx) '
bad=0; netn=0
judge() {   # <label> <log> <exit status> <answers needed> [stress]: JS errors (bar the weather's), crashes (the app's
            # or its web process's), a run that didn't end cleanly, a wall that had to retry building, a page that hung
            # (the harness asks every 3 s; a hung page stops answering) or wasn't answering at the end
  local l="$1" f="$2" st="$3" need="$4" js net crash note last n why=""
  js=$(grep "JSERR" "$f" | grep -Ev "$NET" | grep -c .); net=$(grep "JSERR" "$f" | grep -Ec "$NET")
  crash=$(grep -Ec "CRASH|web process died" "$f")
  note=0; [ "${5:-}" = stress ] || note=$(grep -c "NOTE build failed" "$f")    # (in the stress run, pages are swapped mid-build on purpose)
  last=$(grep "bench fps" "$f" | tail -1)                                     # the page as the run ended: it must be answering
  n=$(grep "bench fps" "$f" | grep -cv "paused: nil\|page loading")
  [ "$n" -lt "$need" ] && why="$why, answered $n times of the $need needed (hung?)"
  netn=$((netn + net))
  [ "$js" -gt 0 ] && why="$why, js errors $js"; [ "$crash" -gt 0 ] && why="$why, crashes $crash"
  [ "$note" -gt 0 ] && why="$why, had to retry building $note×"; [ "$st" -ne 0 ] && why="$why, exited $st$([ "$st" -eq 124 ] && echo " (hung)")"
  # (the stress run swaps walls up to its last second, so a page may be loading as it ends: only its answers count)
  if [ "${5:-}" != stress ] && { [ -z "$last" ] || echo "$last" | grep -q "paused: nil\|page loading"; }; then why="$why, not answering at the end"; fi
  if [ -n "$why" ]; then
    bad=$((bad + 1)); echo "✗ $l: ${why#, }"
    grep -E "JSERR|CRASH|web process died|NOTE build" "$f" | grep -Ev "$NET" | sed 's/\[[0-9]*\] //' | sort | uniq -c | sort -rn | head -3 | sed 's/^/    /'
  else echo "✓ $l$([ "$net" -gt 0 ] && echo "  ($net weather-service errors, not counted)")"; fi
}

# the screen's own pixel scale (2 on a retina display): every wall must draw at it, never below (1.1.0 drew seven at 1.5)
NATIVE=$(swift -e 'import AppKit; print(NSScreen.screens.first.map { Int($0.backingScaleFactor) } ?? 1)' 2>/dev/null || echo 0)
echo "== solo"
for t in railway garden estate gallery inkmap celestial courtyard snow lava wind reef tunnel meadow beach; do
  timeout 40 ./tidewall --bench --behind --themes "$TH" --theme $t --solo --layout mine --secs 12 --fakeicons 9 > "$out/solo-$t.log" 2>&1
  judge "$t" "$out/solo-$t.log" $? 3
  k=$(grep "bench fps" "$out/solo-$t.log" | tail -1 | grep -oE 'dpr=[0-9.]+' | head -1 | cut -d= -f2)
  if [ -n "$k" ] && [ "$NATIVE" != 0 ] && [ "$(echo "$k < $NATIVE" | bc)" = 1 ]; then
    bad=$((bad + 1)); echo "✗ $t draws at ${k}× on a ${NATIVE}× screen: lower resolution than the display"; fi
done

if [ $quick = 0 ]; then
  echo "== world (three displays)"
  WORLD="railway garden estate gallery inkmap celestial snow wind reef meadow beach"
  for t in $WORLD; do
    timeout 50 ./tidewall --bench --behind --themes "$TH" --theme $t --layout auto --fakescreens stacked --secs 16 --fakeicons 9 \
      --snapshot "$out/w-$t.png" > "$out/w-$t.log" 2>&1; st=$?
    [ -n "$PY" ] && "$PY" tools/deskshot.py "$out/w-$t.png" 0.3 >/dev/null 2>&1
    judge "$t" "$out/w-$t.log" $st 4; done
  if [ -n "$PY" ]; then "$PY" tools/visual-check.py "$out" $upd --walls "$WORLD" --displays 3 || bad=$((bad + 1))
  else echo "⚠ no Python with Pillow: pictures not checked (pip3 install pillow)"; fi

  echo "== smoothness (every wall through a window move and its settle, against tools/smooth-baseline.json)"
  tools/smooth.sh "$out/smooth"; sm=$?
  if [ $sm -eq 2 ] || [ $sm -eq 3 ]; then bad=$((bad + 1)); echo "✗ smoothness wasn't measured plugged in: plug in, Low Power Mode off, and run again"
  elif [ $sm -eq 4 ]; then bad=$((bad + 1)); echo "✗ smoothness wasn't measured: the Mac was too busy (other apps); quit them and run again"
  elif [ $sm -ne 0 ]; then bad=$((bad + 1)); fi

  echo "== stress (the Settings window, 95 s)"
  MallocScribble=1 MallocGuardEdges=1 timeout 140 ./tidewall --bench --behind --themes "$TH" --layout auto --fakescreens stacked \
    --away 2 --secs 95 --fakeicons 9 --uistress 0.3 > "$out/stress.log" 2>&1; st=$?
  echo "   $(grep -c uistress "$out/stress.log") actions"
  judge "stress" "$out/stress.log" $st 10 stress
fi

echo
[ "$netn" -gt 0 ] && echo "($netn weather-service errors in all: the service was busy or out of its daily quota; not a Tidewall fault)"
if [ $bad -gt 0 ]; then echo "✗ $bad failed. Logs: $out"; exit 1; fi
echo "✓ all passed. Logs$([ $quick = 0 ] && [ -n "$PY" ] && echo " and the contact sheet (look at it)"): $out"
