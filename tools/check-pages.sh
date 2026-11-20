#!/bin/bash
# Syntax-checks every inline <script> in the theme pages and the app window, and the scripts the host injects into
# every page (themes/host/), with node. Used by CI.
set -uo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); fail=0
for f in themes/*.html themes/ui/index.html; do
  python3 - "$f" "$tmp" <<'PY'
import re, sys, os
src = open(sys.argv[1]).read()
for i, (attrs, js) in enumerate(re.findall(r'<script([^>]*)>(.*?)</script>', src, re.S)):
    if 'src=' in attrs or 'importmap' in attrs or 'x-shader' in attrs or 'text/plain' in attrs: continue
    ext = 'mjs' if 'module' in attrs else 'js'
    open(os.path.join(sys.argv[2], f'{os.path.basename(sys.argv[1])}.{i}.{ext}'), 'w').write(js)
PY
done
shopt -s nullglob
for js in "$tmp"/*.js "$tmp"/*.mjs themes/*.js themes/host/*.js; do node --check "$js" 2>/tmp/check.err || { echo "✗ $js"; head -5 /tmp/check.err; fail=1; }; done
rm -rf "$tmp"; [ $fail = 0 ] && echo "all pages parse"; exit $fail
