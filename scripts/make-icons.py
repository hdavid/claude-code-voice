#!/usr/bin/env python3
"""Renders the menu bar / Control Center icons (Claude mark + sound waves, or struck through) into
Shared/Assets.xcassets as template images. Input: the mark PNGs from Claude.app (Anthropic's mark)."""
import json, math, os, sys
from PIL import Image, ImageDraw

SRC = sys.argv[1] if len(sys.argv) > 1 else "/Applications/Claude.app/Contents/Resources"
OUT = os.path.join(os.path.dirname(__file__), "..", "Shared", "Assets.xcassets")
H, WAVE = 18, 8          # points
SS = 4                   # supersampling


def render(name, muted, scale):
    mark = Image.open(f"{SRC}/TrayIconTemplate{'' if scale == 1 else f'@{scale}x'}.png").convert("RGBA")
    h, mw = H * scale, H * scale
    w = mw + (0 if muted else WAVE * scale)
    big = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    big.alpha_composite(mark.resize((mw * SS, h * SS), Image.LANCZOS))
    d = ImageDraw.Draw(big)
    lw = int((1.6 if muted else 1.5) * scale * SS)
    if muted:
        d.line([(2 * scale * SS, 2 * scale * SS), ((w - 2 * scale) * SS, (h - 2 * scale) * SS)], fill="black", width=lw)
    else:
        cx, cy = (mw - 2 * scale) * SS, h * SS / 2
        for r in (4, 7):
            r *= scale * SS
            d.arc([cx - r, cy - r, cx + r, cy + r], -40, 40, fill="black", width=lw)
    return big.resize((w, h), Image.LANCZOS)


for name, muted in (("VoiceOn", False), ("VoiceMuted", True)):
    d = os.path.join(OUT, f"{name}.imageset")
    os.makedirs(d, exist_ok=True)
    images = []
    for s in (1, 2, 3):
        fn = f"{name}@{s}x.png"
        render(name, muted, s).save(os.path.join(d, fn))
        images.append({"idiom": "universal", "filename": fn, "scale": f"{s}x"})
    json.dump({"images": images, "info": {"version": 1, "author": "xcode"},
               "properties": {"template-rendering-intent": "template"}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)
json.dump({"info": {"version": 1, "author": "xcode"}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
