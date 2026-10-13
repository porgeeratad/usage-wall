"""SpriteCook spritesheet (8 frames in a row) → cleaned strip in art/hero/ for embed.py.
Cleaning, per frame: drop opaque pixels with at most one opaque 4-neighbour (stray tips), then a pixel whose four
neighbours are one tone (luma spread < 14) and which differs from them by > 20 luma takes their colour (stray dots on
the body; eyes survive because their neighbours include eye pixels). The strip is the union crop of all frames, frames side by
side at one width; the page finds each frame's own box at load time.
usage: uv run --with pillow python art/anim_strip.py SHEET.png OUT.png"""
import sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
sh = Image.open(src).convert("RGBA"); fh = sh.height; fw = sh.width // 8
luma = lambda c: 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
N4 = ((1, 0), (-1, 0), (0, 1), (0, -1))
frames, fixed = [], [0, 0]
for i in range(8):
    f = sh.crop((i * fw, 0, i * fw + fw, fh)); p = f.load()
    op = lambda x, y: 0 <= x < fw and 0 <= y < fh and p[x, y][3] > 0
    for x, y in [(x, y) for x in range(fw) for y in range(fh) if op(x, y)]:
        if sum(op(x + dx, y + dy) for dx, dy in N4) <= 1:
            p[x, y] = (0, 0, 0, 0); fixed[0] += 1
    for x in range(1, fw - 1):
        for y in range(1, fh - 1):
            nb = [p[x + dx, y + dy] for dx, dy in N4]
            if p[x, y][3] and all(c[3] for c in nb):
                ls = [luma(c) for c in nb]
                if max(ls) - min(ls) < 14 and abs(luma(p[x, y]) - sum(ls) / 4) > 20:
                    p[x, y] = max(set(nb), key=nb.count); fixed[1] += 1
    frames.append(f)
boxes = [f.getbbox() for f in frames]
x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
x1, y1 = max(b[2] for b in boxes), max(b[3] for b in boxes)
w, h = x1 - x0, y1 - y0
strip = Image.new("RGBA", (w * 8, h))
for i, f in enumerate(frames):
    strip.paste(f.crop((x0, y0, x1, y1)), (i * w, 0))
strip.save(dst, optimize=True)
print(dst, "frame", (w, h), "strays removed", fixed[0], "dots fixed", fixed[1])
