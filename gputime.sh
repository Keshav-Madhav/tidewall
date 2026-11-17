#!/bin/bash
# sum accumulatedGPUTime (ns) for the given comma-separated pids
pids=",$1,"
ioreg -c AGXDeviceUserClient -r -d 1 -w 0 | awk -v pids="$pids" '
  /IOUserClientCreator/ { match($0, /pid [0-9]+/); p = substr($0, RSTART+4, RLENGTH-4); keep = index(pids, "," p ",") > 0 }
  /accumulatedGPUTime/ && keep { s = $0; while (match(s, /accumulatedGPUTime"=[0-9]+/)) { t += substr(s, RSTART+20, RLENGTH-20); s = substr(s, RSTART+RLENGTH) } }
  END { printf "%.0f\n", t }'
