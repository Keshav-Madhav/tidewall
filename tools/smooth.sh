#!/bin/bash
# The smoothness check (tools/regress.sh runs it; release.sh won't tag without it): every wall alone, a window glides
# across it and stops, and every frame the wall's own loop is given is timestamped. tools/smooth-check.py then compares
# the move-and-settle rate, the worst gap and the resting rate with tools/smooth-baseline.json.
#
#   tools/smooth.sh [--update] [<output dir>] [wall … | boat]   (no walls: every wall, then the boat race)
#
# Only meaningful plugged in with Low Power Mode off (macOS throttles everything otherwise): it refuses to run then
# (exit 2). Frame rate is set to Auto for the run (it's the development settings, not your app's). Hidden (--behind).
# A busy Mac starves the wall under test too: before each wall it waits (up to 90 s) for other apps to use no more
# than $TIDEWALL_SMOOTH_BUSY cores (default 4; a quiet Mac runs at 2-3), and a wall that fails while they used more is "not measured: busy"
# (exit 4), not "less smooth". Either way nothing passes that didn't hold its reference: the thresholds don't move.
set -uo pipefail
cd "$(dirname "$0")/.."
upd=""; out=""; walls=()
for a in "$@"; do case "$a" in --update) upd=--update;; */*) out="$a";; *) walls+=("$a");; esac; done
[ ${#walls[@]} -gt 0 ] || walls=(inkmap beach meadow garden estate railway reef snow celestial courtyard wind gallery lava tunnel)
out="${out:-${TMPDIR:-/tmp}/tidewall-smooth-$(date +%Y%m%d-%H%M%S)}"; mkdir -p "$out"
if [ "$(pmset -g | awk '/powermode/ {print $2}')" = 1 ] || { pmset -g batt | grep -q "Battery Power" && [ "${TIDEWALL_SMOOTH_ANY_POWER:-}" != 1 ]; }; then
  echo "⚠ smoothness not measured: plug in and turn Low Power Mode off (on battery, macOS throttles every app)"; exit 2; fi
# TIDEWALL_SMOOTH_ANY_POWER=1: measure on battery anyway (never in Low Power Mode). Indicative only: a run on battery
# exits 3 even when every wall passes, so regress.sh and release.sh never take it as the real measurement
onbat=0; pmset -g batt | grep -q "Battery Power" && onbat=1
# every frame the page's loop is given (and, apart, the ones given while the wall said it was settling: __twSettling)
PROBE='if (!window.__ft) { window.__ft = []; window.__fs = []; let last = 0; const r0 = window.requestAnimationFrame; window.requestAnimationFrame = cb => r0(t => { const n = Date.now(); if (n - last > 4) { window.__ft.push(n); if (window.__twSettling && window.__twSettling()) window.__fs.push(n); if (window.__ft.length > 5000) { window.__ft.shift(); } } last = n; cb(t); }); return "hooked"; } return JSON.stringify({f: window.__ft, s: window.__fs})'
PY=python3; command -v python3 >/dev/null || { echo "✗ needs python3"; exit 1; }
bad=0; busyn=0; BUSY_MAX="${TIDEWALL_SMOOTH_BUSY:-4}"; NCPU=$(sysctl -n hw.ncpu)
# cores in use by everything else right now (a 2 s sample, taken between runs, so none of it is the wall under test)
busy() { top -l 2 -n 0 -s 2 | awk -v n="$NCPU" '/CPU usage/ {u=$3; s=$5} END {sub("%","",u); sub("%","",s); printf "%.1f", (u+s)*n/100}'; }
over() { [ "$(echo "$1 > $BUSY_MAX" | bc)" = 1 ]; }
quiet() { local b; for _ in $(seq 1 18); do b=$(busy); over "$b" || break; sleep 3; done; echo "$b"; }
run() { timeout 60 ./tidewall --bench --behind --fps 0 --themes "${TIDEWALL_SMOOTH_THEMES:-$PWD/themes}" --theme $1 --solo --layout mine \
  --secs 22 --hop 12 --eval-each "$PROBE" --eval-every 1 > "$2" 2>&1; }
# frames the page was given in the 3 s from the move (to pick the healthier of two runs)
frames() { $PY -c 'import re,json,sys; t=open(sys.argv[1],errors="replace").read(); h=re.findall(r"hop starts (\d+)",t); e=re.findall(r"eval \[\d+\] (\{.*\})",t); print(sum(1 for x in json.loads(e[-1])["f"] if int(h[0])<=x<int(h[0])+3000) if h and e else 0)' "$1"; }
for t in "${walls[@]}"; do
  [ "$t" = boat ] && continue                                        # (the boat race is its own test, below)
  load=$(quiet); run $t "$out/smooth-$t.log"
  if [ -n "$upd" ]; then
    # a reference is recorded from the better of two runs: one fluke (a run that stalled) must never become the bar
    run $t "$out/smooth-$t-2.log"
    [ "$(frames "$out/smooth-$t-2.log")" -gt "$(frames "$out/smooth-$t.log")" ] && mv "$out/smooth-$t-2.log" "$out/smooth-$t.log"
    $PY tools/smooth-check.py "$out/smooth-$t.log" "$t" $upd; continue
  fi
  if ! $PY tools/smooth-check.py "$out/smooth-$t.log" "$t" > "$out/smooth-$t.txt"; then
    # one more run before calling it: a wall that is really slower fails both; a one-off stall is reported, not hidden
    mv "$out/smooth-$t.log" "$out/smooth-$t-first.log"; after=$(busy); load2=$(quiet); run $t "$out/smooth-$t.log"
    if $PY tools/smooth-check.py "$out/smooth-$t.log" "$t" > "$out/smooth-$t-retry.txt"; then
      cat "$out/smooth-$t-retry.txt"; echo "    (passed on a second run; the first: $(head -1 "$out/smooth-$t.txt" | cut -c3-120)…)"; retried=$((${retried:-0} + 1))
    elif over "$load" || over "$after" || over "$load2" || over "$(busy)"; then
      busyn=$((busyn + 1)); echo "? $t not measured: other apps were using up to $(printf '%s\n' "$load" "$after" "$load2" | sort -n | tail -1) of $NCPU cores (the first run: $(head -1 "$out/smooth-$t.txt" | cut -c3-90)…)"
    else cat "$out/smooth-$t-retry.txt"; bad=$((bad + 1)); fi
  else cat "$out/smooth-$t.txt"; fi
done
[ "${retried:-0}" -gt 0 ] && echo "⚠ ${retried} wall(s) needed a second run: if the same wall keeps needing one, find out why"
# Ink Map's boat racing to a pointer parked far away (the user saw it stutter: on 30 frames a second it jumped 8 pt a
# frame). While it races it must get at least 3/4 of the display's frames, and step no more than 3.5 pt (median 2.5)
if [ ${#walls[@]} -ge 13 ] || printf '%s\n' "${walls[@]}" | grep -qx boat; then
  hz=$(swift -e 'import AppKit; print(NSScreen.screens.first?.maximumFramesPerSecond ?? 60)' 2>/dev/null || echo 60)
  BP='if (!window.__bt) { window.__bt = []; const r0 = window.requestAnimationFrame; let last = 0; window.requestAnimationFrame = cb => r0(t => { cb(t); const n = performance.now(); if (n - last > 4) { window.__bt.push([Math.round(n), Math.round(B.x * 10) / 10, Math.round(B.y * 10) / 10, Math.round(Math.hypot(B.vx, B.vy))]); if (window.__bt.length > 4000) window.__bt.shift(); } last = n; }); return "hooked"; } return JSON.stringify(window.__bt)'
  timeout 60 ./tidewall --bench --behind --fps 0 --themes "${TIDEWALL_SMOOTH_THEMES:-$PWD/themes}" --theme inkmap --solo --secs 20 \
    --film "$out/boatfilm" --film-start 3 --film-dur 15 --film-noshots --choreo tools/smooth-boat.json --eval-each "$BP" --eval-every 1 > "$out/smooth-boat.log" 2>&1
  $PY - "$out/smooth-boat.log" "$hz" <<'PY' || bad=$((bad + 1))
import sys, re, json, math
txt = open(sys.argv[1], errors='replace').read(); hz = float(sys.argv[2]); ev = re.findall(r'eval \[\d+\] (\[\[.*\]\])', txt)
if not ev: print('✗ boat       no measurement'); sys.exit(1)
d = json.loads(ev[-1]); fast = [(a, b) for a, b in zip(d, d[1:]) if b[3] > 60]
if not fast: print('✗ boat       never raced to the pointer'); sys.exit(1)
steps = sorted(math.hypot(b[1] - a[1], b[2] - a[2]) for a, b in fast); dur = sum(b[0] - a[0] for a, b in fast) / 1000
rate, med, p95 = len(fast) / dur, steps[len(steps) // 2], steps[int(len(steps) * .95)]
line = f"boat       racing {dur:4.1f} s at {rate:5.1f} fps, step per frame median {med:.1f} pt, 95% {p95:.1f}"
why = [w for w, bad in [(f"{rate:.0f} fps < {0.75 * hz:.0f}", rate < 0.75 * hz), (f"median step {med:.1f} pt > 2.5", med > 2.5), (f"95% step {p95:.1f} pt > 3.5", p95 > 3.5)] if bad]
print(('✗ ' + line + '\n    ' + '; '.join(why)) if why else '✓ ' + line); sys.exit(1 if why else 0)
PY
fi
[ $bad -eq 0 ] || { echo "✗ smoothness: $bad wall(s) got less smooth (logs: $out)"; exit 1; }
[ $busyn -eq 0 ] || { echo "? smoothness: $busyn wall(s) not measured, the Mac was too busy: quit the heavy apps and run again (logs: $out)"; exit 4; }
if [ $onbat = 1 ]; then echo "~ smoothness: all ${#walls[@]} walls hold their reference, measured on battery: indicative only, run again plugged in"; exit 3; fi
echo "✓ smoothness: all ${#walls[@]} walls hold their reference"
