#!/bin/bash
# usage: tools/thumbs.sh [theme ...]   → themes/ui/thumbs/<theme>.jpg for each (all themes if none given)
# Renders each theme on the `showcase` test desktop and draws the mock windows in. Run from the repo root after building ./tidewall.
set -euo pipefail
cd "$(dirname "$0")/.."
themes=("$@"); [ ${#themes[@]} -eq 0 ] && themes=(estate gallery garden railway inkmap lava snow celestial courtyard wind reef tunnel meadow beach)
tmp=$(mktemp -d)
for t in "${themes[@]}"; do
  ./tidewall --bench --themes "$PWD/themes" --layout showcase --theme "$t" --secs 18 --snapshot "$tmp/$t.png" > "$tmp/$t.log" 2>&1
  python3 tools/thumbs.py "$tmp/$t.png" "themes/ui/thumbs/$t.jpg"
done
rm -rf "$tmp"
