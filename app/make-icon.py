"""Maintainer tool: render app/AppIcon.icns from art/hero/medium.png (pixel Clawd on a dark rounded tile, nearest-
neighbour so the pixels stay crisp). The .icns is committed, so building the app does not need Pillow.
usage: uv run --with pillow python app/make-icon.py"""
import os, shutil, subprocess, tempfile
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
hero = Image.open(os.path.join(ROOT, "art/hero/medium.png")).convert("RGBA")
hero = hero.crop(hero.getbbox())


def render(size):
    if size < 256:                                  # draw big, then reduce: small icons keep their shape
        return render(512).resize((size, size), Image.LANCZOS)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = round(size * 0.09); r = round(size * 0.2)
    d.rounded_rectangle((pad, pad, size - pad, size - pad), radius=r, fill=(22, 20, 40, 255))
    d.rounded_rectangle((pad, round(size * 0.62), size - pad, size - pad), radius=r, fill=(52, 120, 64, 255))
    d.rectangle((pad, round(size * 0.62), size - pad, round(size * 0.70)), fill=(76, 175, 80, 255))
    k = max(1, int((size - 2 * pad) * 0.8 // hero.width))
    h = hero.resize((hero.width * k, hero.height * k), Image.NEAREST)
    img.alpha_composite(h, ((size - h.width) // 2, round(size * 0.66) - h.height))
    return img


tmp = tempfile.mkdtemp(); iconset = os.path.join(tmp, "AppIcon.iconset"); os.makedirs(iconset)
for base in (16, 32, 128, 256, 512):
    render(base).save(os.path.join(iconset, f"icon_{base}x{base}.png"))
    render(base * 2).save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ROOT, "app/AppIcon.icns")], check=True)
render(512).save(os.path.join(tmp, "preview.png")); shutil.copy(os.path.join(tmp, "preview.png"), os.path.join(ROOT, "app/AppIcon-preview.png"))
shutil.rmtree(tmp); print("app/AppIcon.icns")
