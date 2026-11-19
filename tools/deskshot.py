#!/usr/bin/env python3
"""Composite the per-display snapshots of a `--fakescreens` bench run into one picture of the whole desk.

  ./tidewall --bench --themes "$PWD/themes" --theme railway --layout world3 --fakescreens stacked \\
      --secs 14 --snapshot /tmp/desk.png
  python3 tools/deskshot.py /tmp/desk.png        # writes /tmp/desk-desk.jpg

Each page saved <base>-<id>.png; <base>-layout.json says where each display sits (CG points). The gaps between
displays are drawn dark, as on a real desk.
"""
import json, os, sys
from PIL import Image

base = os.path.splitext(sys.argv[1])[0]
lay = json.load(open(base + '-layout.json'))
x0 = min(f[0] for f in lay.values()); y0 = min(f[1] for f in lay.values())
x1 = max(f[0] + f[2] for f in lay.values()); y1 = max(f[1] + f[3] for f in lay.values())
k = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5             # output points → pixels
desk = Image.new('RGB', (int((x1 - x0) * k), int((y1 - y0) * k)), (18, 18, 20))
for id_, (x, y, w, h) in lay.items():
    p = f'{base}-{id_}.png'
    if not os.path.exists(p): continue
    im = Image.open(p).convert('RGB').resize((int(w * k), int(h * k)), Image.LANCZOS)
    desk.paste(im, (int((x - x0) * k), int((y - y0) * k)))
desk.save(base + '-desk.jpg', quality=85)
print(base + '-desk.jpg', desk.size)
