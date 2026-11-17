#!/bin/bash
# usage: matrix.sh <theme> <rounds> "label|args" ...   → median per config
th=$1; rounds=$2; shift 2
cd "$(dirname "$0")"; : > /tmp/matrix.txt
for r in $(seq 1 $rounds); do for cfg in "$@"; do
  ./bench.sh "${cfg%%|*}" 6 -- --theme $th ${cfg#*|} | tee -a /tmp/matrix.txt >/dev/null
done; done
python3 - "$th" <<'PY'
import re, sys, statistics as st, collections
rows = collections.defaultdict(list)
for l in open('/tmp/matrix.txt'):
    m = re.match(r'(.{22}) scene-GPU\s+([\d.]+)%\s+WindowServer-GPU\s+([\d.]+)%\s+CPU\(app\+web\)\s+([\d.]+)%', l)
    if m: rows[m.group(1).strip()].append(tuple(map(float, m.group(2, 3, 4))))
for k, v in rows.items():
    g, w, c = (st.median(x) for x in zip(*v))
    print(f"{sys.argv[1]:7s} {k:18s} scene-GPU {g:5.1f}%  WindowServer {w:5.1f}%  CPU {c:5.1f}%   runs={[x[0] for x in v]}")
PY
