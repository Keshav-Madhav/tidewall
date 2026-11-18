#!/bin/bash
# usage: bench.sh <label> <secs> -- tidewall args...   (GPU% = GPU-busy time of the process / wall time)
label=$1; secs=$2; shift 3
cd "$(dirname "$0")"
./tidewall --bench --themes "$PWD/themes" --secs $((secs+7)) "$@" > /tmp/tidewall-bench.log 2>&1 &
app=$!
sleep 6
python3 "$(dirname "$0")/gputime.py" > /tmp/g0.json; t0=$(python3 -c "import time;print(time.time())")
web=$(grep -o 'webpid=[0-9]*' /tmp/tidewall-bench.log | tail -1 | cut -d= -f2)
n=0; cpu=0
for i in $(seq 1 $((secs*2))); do
  c=$(ps -o %cpu= -p "$app${web:+,$web}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
  cpu=$(echo "$cpu+$c" | bc); n=$((n+1)); sleep 0.5
done
python3 "$(dirname "$0")/gputime.py" > /tmp/g1.json; t1=$(python3 -c "import time;print(time.time())")
wait $app 2>/dev/null
python3 - "$label" "$t0" "$t1" "$(echo "scale=1; $cpu/$n" | bc)" "$(grep bench /tmp/tidewall-bench.log | tail -1 | sed 's/bench fps\/fieldMs\/buffer\/paused: //')" "$app" <<'PY'
import json, sys
label, t0, t1, cpu, info, app = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
a, b = json.load(open('/tmp/g0.json')), json.load(open('/tmp/g1.json'))
el = t1 - t0
def d(pred): return sum(b[p][1] - a[p][1] for p in b if p in a and pred(p, b[p][0])) / el / 1e7
wk = d(lambda p, n: p == app)
ws = d(lambda p, n: n == 'WindowServer')
print(f"{label:22s} scene-GPU {wk:5.1f}%  WindowServer-GPU {ws:5.1f}%  CPU(app+web) {float(cpu):5.1f}%  | {info}")
PY
grep -E 'JSERR' /tmp/tidewall-bench.log | head -3
