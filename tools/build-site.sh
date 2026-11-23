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
# every wall runs live on the page (the visitor picks one under "Try it live"; only that one's files load)
for f in themes/*.html; do
  wall=$(basename "$f" .html)
  sed 's#<head>#<head><script src="shim.js"></script>#' "$f" > "$out/walls/$wall.html"
  grep -q 'src="shim.js"' "$out/walls/$wall.html" || { echo "✗ $f has no <head> to put the shim in"; exit 1; }
done
cp site/wall-shim.js "$out/walls/shim.js"
cp themes/*.js themes/*.jpg themes/variants.json "$out/walls/"
rsync -a --exclude .DS_Store themes/railway themes/sky themes/snow themes/wind themes/lib themes/gallery themes/assets themes/host "$out/walls/"
# Wind Tunnel's default model only (the others, 90 MB, are for the app's model picker)
mkdir -p "$out/walls/tunnel/models"; rsync -a --exclude .DS_Store --exclude models themes/tunnel/ "$out/walls/tunnel/"
cp themes/tunnel/models/x1.glb "$out/walls/tunnel/models/"
cp themes/ui/thumbs/*.jpg "$out/img/"
echo "built $out ($(du -sh "$out" | cut -f1))"
