#!/bin/bash
# Builds the website into build/site: site/ as it is, plus the walls it runs and the wall thumbnails, copied from
# themes/ so the site always runs the same walls the app ships.
#
#   tools/build-site.sh            then: (cd build/site && python3 -m http.server 8000) → http://localhost:8000
#
# The site embeds walls with tw-embed.js; each wall gets wall-shim.js, which lets a web page play Tidewall's part.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/site
mkdir -p "$out"
rsync -a --delete --exclude .DS_Store --exclude wall-shim.js site/ "$out/"
mkdir -p "$out/walls" "$out/img"
for wall in inkmap; do
  sed 's#<head>#<head><script src="shim.js"></script>#' "themes/$wall.html" > "$out/walls/$wall.html"
  grep -q 'src="shim.js"' "$out/walls/$wall.html" || { echo "✗ themes/$wall.html has no <head> to put the shim in"; exit 1; }
done
cp site/wall-shim.js "$out/walls/shim.js"
cp themes/companion.js themes/span.js "$out/walls/"
cp themes/ui/thumbs/*.jpg "$out/img/"
echo "built $out ($(du -sh "$out" | cut -f1))"
