#!/usr/bin/env python3
"""Turns a --bench snapshot of the `showcase` desktop into a gallery thumbnail: draws the two mock windows the bench
leaves bare, crops to 16:10 and saves a 960x600 JPEG.   usage: thumbs.py snapshot.png out.jpg   (needs Pillow)"""
import sys
from PIL import Image, ImageDraw, ImageFilter

WINS = [((250, 190, 620, 410), 'dark'), ((840, 430, 470, 320), 'light')]   # the showcase layout, in points (main.swift)

def window(img, k, x, y, w, h, kind):
    x, y, w, h = [v * k for v in (x, y, w, h)]
    sh = Image.new('RGBA', img.size, (0, 0, 0, 0)); ImageDraw.Draw(sh).rounded_rectangle((x, y + 15 * k, x + w, y + h + 15 * k), 12 * k, fill=(0, 0, 0, 110))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(20 * k)))
    body = Image.new('RGBA', img.size, (0, 0, 0, 0)); d = ImageDraw.Draw(body)
    d.rounded_rectangle((x, y, x + w, y + h), 12 * k, fill=(32, 33, 36, 242) if kind == 'dark' else (250, 250, 252, 246), outline=(0, 0, 0, 80), width=k)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        d.ellipse((x + (14 + i * 20) * k, y + 14 * k, x + (26 + i * 20) * k, y + 26 * k), fill=c + (255,))
    img.alpha_composite(body)
    lines = Image.new('RGBA', img.size, (0, 0, 0, 0)); d = ImageDraw.Draw(lines); c = (255, 255, 255, 34) if kind == 'dark' else (0, 0, 0, 24)
    for i, f in enumerate([.7, .92, .55, .8, .64, .75][: int((h / k - 60) / 28)]):
        d.rounded_rectangle((x + 18 * k, y + (55 + i * 28) * k, x + 18 * k + (w - 36 * k) * f, y + (65 + i * 28) * k), 5 * k, fill=c)
    img.alpha_composite(lines)

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGBA'); k = round(im.width / 1512) or 1
for (x, y, w, h), kind in WINS: window(im, k, x, y, w, h, kind)
W = im.width; Hc = int(W / 1.6); top = (im.height - Hc) // 2
im.crop((0, top, W, top + Hc)).convert('RGB').resize((960, 600), Image.LANCZOS).save(out, quality=84, optimize=True, progressive=True)
print('wrote', out)
