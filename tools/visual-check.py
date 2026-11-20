#!/usr/bin/env python3
"""The regression suite's eyes: every wall's snapshot from a `--fakescreens` run, checked and laid out for a look.

  python3 tools/visual-check.py <dir> [--update] [--walls "railway garden …" --displays 3]

<dir> holds w-<wall>-<display>.png (tools/regress.sh writes them). For each one:
  FAIL  a display the run laid out has no picture, or the picture is flat (one colour, or nearly): the wall never
        drew, or drew nothing.
  WARN  it looks very different from its reference in tools/visual-baseline.json (a tiny greyscale thumbnail per wall
        and display). Some walls change by themselves (the real sky, the weather, day and night), so this only asks
        for a look. Each keeps up to 3 references (day and night, say); --update adds today's look where it's new,
        once you've looked.
Writes <dir>/sheet.jpg: every wall's whole desk on one page, to look at before a release. Exits 1 on any FAIL.
"""
import glob, json, os, re, sys
from PIL import Image, ImageDraw, ImageStat

here = os.path.dirname(os.path.abspath(__file__))
base_path = os.path.join(here, 'visual-baseline.json')
d = sys.argv[1]; update = '--update' in sys.argv
def arg(k, default=None):
    return sys.argv[sys.argv.index(k) + 1] if k in sys.argv and sys.argv.index(k) + 1 < len(sys.argv) else default
expect = (arg('--walls') or '').split(); need = int(arg('--displays', '0'))
base = json.load(open(base_path)) if os.path.exists(base_path) else {}
TW, TH, FLAT, DIFF = 32, 18, 4.0, 45.0

fails, warns, new, diffs, flat = [], [], {}, {}, set()
# up to MAXREF references per wall and display: walls that change with the time of day (Wind Map's day and night
# palettes, say) keep one of each, and only a picture unlike all of them asks for a look
MAXREF = 3
def refs_of(key):
    r = base.get(key) or []
    return [r] if r and isinstance(r[0], int) else r
# every wall the suite ran must have laid out its displays (--walls, --displays), and every display its picture: what
# the app never wrote is a failure, not a pass
walls = sorted(set(expect) | {os.path.basename(x)[2:-12] for x in glob.glob(os.path.join(d, 'w-*-layout.json'))})
for wall in walls:
    lay = os.path.join(d, f'w-{wall}-layout.json')
    if not os.path.exists(lay): fails.append(f'{wall}: no layout written (the run took no pictures)'); continue
    ids = list(json.load(open(lay)))
    if len(ids) < need: fails.append(f'{wall}: {len(ids)} displays laid out, expected {need}')
    for id_ in ids:
        if not os.path.exists(os.path.join(d, f'w-{wall}-{id_}.png')): fails.append(f'{wall}-{id_}: no picture was taken')
for p in sorted(glob.glob(os.path.join(d, 'w-*-*.png'))):
    m = re.match(r'w-(.+)-(\d+)\.png$', os.path.basename(p))
    if not m: continue
    key = f'{m.group(1)}-{m.group(2)}'
    im = Image.open(p).convert('L')
    small = im.resize((320, max(1, 320 * im.height // im.width)))
    sd = ImageStat.Stat(small).stddev[0]
    t = im.resize((TW, TH), Image.BILINEAR)
    thumb = list(t.get_flattened_data() if hasattr(t, 'get_flattened_data') else t.getdata())
    new[key] = thumb
    if sd < FLAT:
        fails.append(f'{key}: flat picture (contrast {sd:.1f}): the wall drew nothing'); flat.add(key)
    else:
        refs = refs_of(key)
        diff = min((sum(abs(a - b) for a, b in zip(thumb, r)) / len(thumb) for r in refs if len(r) == len(thumb)), default=None)
        diffs[key] = diff
        if diff is None:
            if not update: warns.append(f'{key}: no reference yet (--update to keep this one)')
        elif diff > DIFF: warns.append(f'{key}: looks unlike its references (difference {diff:.0f}): have a look')

desks = sorted(glob.glob(os.path.join(d, 'w-*-desk.jpg')))
if desks:
    tiles = [Image.open(p).convert('RGB') for p in desks]
    w = 520; tiles = [t.resize((w, max(1, w * t.height // t.width))) for t in tiles]
    cols = 3; rows = (len(tiles) + cols - 1) // cols; th = max(t.height for t in tiles) + 22
    sheet = Image.new('RGB', (cols * (w + 10) + 10, rows * th + 10), (24, 24, 26)); dr = ImageDraw.Draw(sheet)
    for i, (t, p) in enumerate(zip(tiles, desks)):
        x, y = 10 + (i % cols) * (w + 10), 10 + (i // cols) * th
        sheet.paste(t, (x, y + 18)); dr.text((x, y + 2), os.path.basename(p)[2:-9], fill=(230, 230, 230))
    sheet.save(os.path.join(d, 'sheet.jpg'), quality=82)

if update:   # a picture like an existing reference changes nothing; a new look is added (the oldest goes past MAXREF)
    added = 0
    for key, thumb in new.items():
        if key in flat or (diffs.get(key) is not None and diffs[key] <= DIFF): continue   # (never a broken picture)
        base[key] = (refs_of(key) + [thumb])[-MAXREF:]; added += 1
    json.dump(base, open(base_path, 'w'), separators=(',', ':'), sort_keys=True)
    print(f'references: {added} new looks kept')
for f in fails: print('FAIL', f)
for w_ in warns: print('WARN', w_)
print(f'visual: {len(new)} pictures, {len(fails)} failed, {len(warns)} to look at; sheet: {os.path.join(d, "sheet.jpg")}')
sys.exit(1 if fails else 0)
