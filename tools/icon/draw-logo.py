#!/usr/bin/env python3
"""SyncPlayer logo, round 3 (Akira 11/25: not amateur; may use the word Sync). -> G/H/I.png sheet3.png"""
import math
from PIL import Image, ImageDraw, ImageFont, ImageChops
S = 4096
FD = "/usr/share/fonts/opentype/inter/"
def font(name, size): return ImageFont.truetype(FD + name, size)

def grad(c0, c1):
    """Diagonal gradient, top-left c0 to bottom-right c1."""
    g = Image.new("RGB", (S, S)); px = []
    small = Image.new("RGB", (256, 256))
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            small.putpixel((x, y), tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)))
    return small.resize((S, S), Image.BICUBIC)

def squircle_mask():
    m = Image.new("L", (S, S), 0); d = ImageDraw.Draw(m)
    k = S * 100 // 1024
    d.rounded_rectangle((k, k, S - k, S - k), radius=S * 185 // 1024, fill=255)
    return m

def icon(bg, art):
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    im.paste(bg, (0, 0), squircle_mask())
    im.alpha_composite(art)
    return im

def G():  # bold S monogram, cut by three thin gaps: several streams that line up into one letter
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(art)
    f = font("InterDisplay-Black.otf", int(S * 0.62))
    bb = d.textbbox((0, 0), "S", font=f)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    d.text(((S - w) / 2 - bb[0], (S - h) / 2 - bb[1]), "S", font=f, fill=(255, 255, 255, 255))
    # gaps
    cut = Image.new("L", (S, S), 255); dc = ImageDraw.Draw(cut)
    top = (S - h) / 2
    for k in (1, 2, 3, 4):
        y = top + h * k / 5
        dc.rectangle((0, y - S * 0.007, S, y + S * 0.007), fill=0)
    a = ImageChops.multiply(art.getchannel("A"), cut); art.putalpha(a)
    return icon(grad((20, 24, 40), (40, 70, 160)), art)

def H():  # concentric rings, each with a gap, all gaps lined up: phases in sync
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(art)
    c = S / 2; w = S * 0.042
    cols = [(255, 255, 255, 255)] * 3
    for i, r in enumerate((S * 0.30, S * 0.22, S * 0.14)):
        d.arc((c - r, c - r, c + r, c + r), start=-40, end=280, fill=cols[i], width=int(w))
    # the shared moment: a dot where the gaps line up
    a = math.radians(-60); r = S * 0.30
    d.ellipse((c + r * math.cos(a) - w * 0.75, c + r * math.sin(a) - w * 0.75,
               c + r * math.cos(a) + w * 0.75, c + r * math.sin(a) + w * 0.75), fill=(255, 196, 61, 255))
    # Deep blue ground (Akira 2026-11-27: same deep-blue base as the site and SyncMapper, was grey (14,16,22)->(34,38,52)).
    # The shipped docs/logo.png and AppIcon.iconset are lecture-web's recolour (claude-shared-docs projects/lecture-web/syncplayer-icon-blue-1024.png), which this matches closely.
    return icon(grad((8, 26, 72), (22, 58, 128)), art)

def I():  # wordmark icon: "Sync" set tight, with a play-head bar through it
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(art)
    f = font("InterDisplay-ExtraBold.otf", int(S * 0.27))
    t = "Sync"; bb = d.textbbox((0, 0), t, font=f)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    x0, y0 = (S - w) / 2 - bb[0], (S - h) / 2 - bb[1] - S * 0.02
    d.text((x0, y0), t, font=f, fill=(255, 255, 255, 255))
    y = (S + h) / 2 + S * 0.06
    d.rounded_rectangle(((S - w) / 2, y, (S + w) / 2, y + S * 0.022), radius=S * 0.011, fill=(255, 255, 255, 70))
    d.rounded_rectangle(((S - w) / 2, y, (S - w) / 2 + w * 0.62, y + S * 0.022), radius=S * 0.011, fill=(255, 196, 61, 255))
    return icon(grad((255, 120, 60), (200, 40, 110)), art)

out = {}
for n, fn in (("G", G), ("H", H), ("I", I)):
    im = fn().resize((1024, 1024), Image.LANCZOS); im.save(f"{n}.png"); out[n] = im
# Sheet: icon large, sizes, and the logotype beside a small icon, on light and dark
lab = font("Inter-SemiBold.otf" if False else "InterDisplay-SemiBold.otf", 40)
word = font("InterDisplay-SemiBold.otf", 64)
sh = Image.new("RGB", (3 * 760, 1000), (238, 238, 240)); d = ImageDraw.Draw(sh)
d.rectangle((0, 800, 3 * 760, 1000), fill=(22, 24, 30))
for i, n in enumerate("GHI"):
    x = i * 760 + 40
    big = out[n].resize((460, 460), Image.LANCZOS); sh.paste(big, (x, 70), big)
    for j, sz in enumerate((128, 64, 32, 16)):
        sm = out[n].resize((sz, sz), Image.LANCZOS); sh.paste(sm, (x + [0, 150, 236, 290][j], 580 + (128 - sz) // 2), sm)
    d.text((x, 14), f"案 {n}" if False else n, font=lab, fill=(40, 40, 40))
    for k, (yy, col) in enumerate(((720, (20, 20, 24)), (870, (245, 245, 245)))):
        sm = out[n].resize((80, 80), Image.LANCZOS); sh.paste(sm, (x, yy - 30), sm)
        d.text((x + 100, yy - 26), "SyncPlayer", font=word, fill=col)
sh.save("sheet3.png")
