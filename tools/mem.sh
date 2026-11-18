#!/bin/bash
# usage: tools/mem.sh THEME [tidewall args] → memory footprint of one theme's page on the main screen, after 14 s
cd "$(dirname "$0")/.."; t=$1; shift
./tidewall --bench --theme $t --secs 20 "$@" >/tmp/tidewall-mem.log 2>&1 & app=$!; sleep 14
web=$(grep -o 'webpid=[0-9]*' /tmp/tidewall-mem.log | tail -1 | cut -d= -f2)
fp() { footprint $1 2>/dev/null | grep -m1 Footprint | sed -E 's/.*Footprint: ([0-9.]+) (MB|KB|GB).*/\1 \2/' | awk '{ if ($2=="KB") print $1/1024; else if ($2=="GB") print $1*1024; else print $1 }'; }
gr=$(footprint $web 2>/dev/null | grep -m1 "(graphics)" | awk '{ v=$1; if ($2=="KB") v/=1024; if ($2=="GB") v*=1024; print v }')
printf "%-10s host %4.0f  page %5.0f MB (graphics %4.0f)\n" $t $(fp $app) $(fp $web) ${gr:-0}
wait $app 2>/dev/null
