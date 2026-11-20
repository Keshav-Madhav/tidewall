#!/usr/bin/env python3
"""Reads one smoothness run (tools/smooth.sh) and says whether the wall stayed smooth through a window move.

  smooth-check.py <log> <wall> [baseline.json] [--update]

The log holds "bench: hop starts <epoch ms>" (when the harness began gliding a window) and the probe's frame times
(epoch ms): every frame the page's loop was given, and apart the ones given while the wall said it was still settling
(window.__twSettle: a morph, beds easing, a cross-fade). Three rules, against the wall's reference in
tools/smooth-baseline.json (profile: frames a second in each quarter-second for 3 s from the move; rest: its calm rate):

  1 settling  while the wall says it's settling, every quarter-second it spends wholly settling runs at least
              max(40, 2 × its calm rate). This is the rule the 1.1.0 regression broke (a morph drawn at the calm 12
              fps), and it holds however busy the Mac is and whenever the settle ends.
  2 dropping  a wall that forgot to say so is caught by its rate collapsing to its calm level (calm × 1.5 + 5) for two
              quarter-seconds where its reference still ran fast (≥ 40), not counting the reference's last half second
              (a transition may finish a little sooner one run than another; finishing sooner is fine).
  3 resting   10-12 s after the move (long after any transition): no faster than its reference rest (+20% and 3 fps),
              and not still settling: a wall stuck boosted costs power all day.

--update records this run as the reference: only after a deliberate change you have looked at, never to make a slower
wall pass (tools/smooth.sh --update takes the better of two runs, so a stalled run can't become the bar).
"""
import json, os, re, sys

log, wall = sys.argv[1], sys.argv[2]
base_path = sys.argv[3] if len(sys.argv) > 3 and not sys.argv[3].startswith('--') else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'smooth-baseline.json')
update = '--update' in sys.argv
txt = open(log, errors='replace').read()
hop = re.findall(r'bench: hop starts (\d+)', txt)
evs = re.findall(r'eval \[\d+\] (\{.*\})', txt)
if not hop or not evs:
    print(f'✗ {wall}: no measurement (the run never glided a window or the probe never answered)'); sys.exit(1)
T = int(hop[0]); d = json.loads(evs[-1]); ft, fs = d['f'], d['s']
end = max(ft) if ft else T
def rate(xs, a, b): return sum(1 for t in xs if a <= t < b) * 1000 / (b - a)
slices = [round(rate(ft, T + i * 250, T + (i + 1) * 250)) for i in range(12)]
rest = round(rate(ft, T + 10000, T + 12000), 1)                          # 10-12 s after the move: long settled
rest_settling = rate(fs, T + 10000, T + 12000) / max(rest, 0.1)
base = json.load(open(base_path)) if os.path.exists(base_path) else {}
ref = base.get(wall)
if not ft or (not any(slices) and not rest):
    print(f"– {wall:10s} no frame loop (it animates on the compositor): nothing to measure"); sys.exit(0)
calm = ref['rest'] if ref else rest; calm = calm if calm > 0 else 30      # (a wall that stops at rest: 30)
floor = max(40, 2 * calm)
# 1: quarter-seconds spent wholly settling (settling frames from start to end, no gap over 150 ms)
why, settle_q = [], []
stretches, cur = [], []
for t in (x for x in fs if x >= T - 250):                                 # (from the move: not the page's start-up)
    if cur and t - cur[-1] > 150: stretches.append(cur); cur = []
    cur.append(t)
if cur: stretches.append(cur)
for st in stretches:
    a = st[0]
    while a + 250 <= st[-1]:
        q = rate(st, a, a + 250); settle_q.append(q)
        if q < floor: why.append(f"settling at {q:.0f} fps (needs ≥ {floor:.0f}) {(a - T) / 1000:+.2f}s from the move")
        a += 250
# 2: collapsed to the calm rate where the reference ran fast
if ref:
    prof = ref['profile']; fast = [i for i, r in enumerate(prof) if r >= 40]
    upto = (max(fast) - 1) if fast else -1                                    # (the reference's last half second excused)
    calm_hi = calm * 1.5 + 5
    low = [i for i in range(min(upto, len(slices))) if prof[i] >= 40 and slices[i] <= calm_hi]
    if len(low) >= 2: why.append('dropped to its calm rate while its reference still ran fast: ' + ', '.join(f"{i * .25:.2f}s {slices[i]} fps (was {prof[i]})" for i in low))
# 3: at rest
    if rest > ref['rest'] * 1.2 + 3: why.append(f"resting at {rest} fps (reference {ref['rest']})")
if rest_settling > 0.5: why.append(f"still settling at rest ({rest_settling:.0%} of its last 2 s): stuck at the full rate")
worst = min(settle_q) if settle_q else None
line = (f"{wall:10s} settling ≥ {worst:3.0f} fps over {len(settle_q):2d} quarter-seconds, " if settle_q else f"{wall:10s} (no settling signalled),{' ' * 29}") + \
       f"rest {rest:5.1f} fps  quarter-seconds from the move: {' '.join(str(x) for x in slices)}"
if update:
    if why: print('✗ ' + line + '\n    not recorded: ' + '; '.join(why)); sys.exit(1)
    base[wall] = {'profile': slices, 'rest': rest}; json.dump(base, open(base_path, 'w'), indent=1, sort_keys=True); print('• ' + line + '  [reference recorded]'); sys.exit(0)
if why: print('✗ ' + line + '\n    ' + '; '.join(why)); sys.exit(1)
print(('✓ ' if ref else '? ') + line + ('' if ref else '  [no reference yet]'))
