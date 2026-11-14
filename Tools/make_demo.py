#!/usr/bin/env python3
"""Render the TuyaGlow demo: a dark room, a monitor, and a bulb that follows it.

    pip install pillow numpy && python3 Tools/make_demo.py   # needs ffmpeg
Writes docs/demo.mp4, docs/demo.gif and docs/og-image.png.
"""
import colorsys
import math
import os
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H, FPS = 960, 540, 20
OUT = os.path.join(os.path.dirname(__file__), "..", "docs")
FONT = "/System/Library/Fonts/HelveticaNeue.ttc"
f_cap = ImageFont.truetype(FONT, 26, index=1)
f_sub = ImageFont.truetype(FONT, 17)
f_ui = ImageFont.truetype(FONT, 13)
f_ui_b = ImageFont.truetype(FONT, 13, index=1)

BPM = 124
BEAT = 60 / BPM
NEON = [300, 190, 60, 330, 140, 260]
# Scenes: (name, start, end)
SCENES = [("music", 0.0, 7.7), ("drop", 7.7, 9.6), ("screen", 9.6, 14.6), ("light", 14.6, 17.0)]
DUR = SCENES[-1][2]

yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
BULB = (640, 120)      # pendant bulb position
MON = (120, 250, 470, 450)  # monitor screen box (x0, y0, x1, y1)


def hsv(h, s=1.0, v=1.0):
    return np.array(colorsys.hsv_to_rgb((h % 360) / 360, s, v), dtype=np.float32)


def base_room():
    img = np.zeros((H, W, 3), np.float32)
    wall = np.array([0.075, 0.068, 0.062])
    img[:] = wall * (0.85 + 0.15 * (1 - yy[..., None] / H))
    floor = yy > 470
    img[floor] = np.array([0.05, 0.043, 0.038])
    return img


ROOM = base_room()


def glow(color, intensity, cx, cy, radius):
    d2 = ((xx - cx) ** 2 + (yy - cy) ** 2) / (radius ** 2)
    return np.exp(-d2)[..., None] * color[None, None, :] * intensity


def screen_content(t, scene):
    """Return (image HxW of the monitor, its average color)."""
    x0, y0, x1, y1 = MON
    w, h = x1 - x0, y1 - y0
    sy, sx = np.mgrid[0:h, 0:w].astype(np.float32)
    if scene == "screen":
        k = (t - 9.6) / 5.0
        # a "movie": sunset -> ocean -> forest
        stops = [(0.0, (0.95, 0.45, 0.15), (0.35, 0.08, 0.25)), (0.45, (0.10, 0.45, 0.85), (0.02, 0.12, 0.30)),
                 (1.0, (0.20, 0.70, 0.30), (0.03, 0.18, 0.08))]
        for i in range(len(stops) - 1):
            if stops[i][0] <= k <= stops[i + 1][0] or i == len(stops) - 2:
                a, b = stops[i], stops[i + 1]
                u = min(1, max(0, (k - a[0]) / (b[0] - a[0])))
                top = np.array(a[1]) * (1 - u) + np.array(b[1]) * u
                bot = np.array(a[2]) * (1 - u) + np.array(b[2]) * u
                break
        img = top[None, None, :] * (1 - sy[..., None] / h) + bot[None, None, :] * (sy[..., None] / h)
        sun = np.exp(-(((sx - w * (0.3 + 0.4 * k)) ** 2 + (sy - h * 0.45) ** 2) / (40 ** 2)))[..., None]
        img = np.clip(img + sun * np.array([1.0, 0.85, 0.6]) * 0.7, 0, 1)
        return img, img.reshape(-1, 3).mean(0)
    # music player: dark UI with bars
    img = np.full((h, w, 3), 0.09, np.float32)
    img[:, :] = np.array([0.085, 0.08, 0.075])
    phase = (t % BEAT) / BEAT
    n = 28
    for i in range(n):
        level = 0.25 + 0.6 * abs(math.sin(i * 1.7 + t * 3.1)) * (1.0 - 0.6 * phase if i < 8 else 0.7)
        bx0 = int(20 + i * (w - 40) / n)
        bx1 = int(bx0 + (w - 40) / n - 3)
        bh = int(level * (h - 80))
        img[h - 40 - bh:h - 40, bx0:bx1] = np.array([0.85, 0.62, 0.35]) * (0.6 + 0.4 * (1 - phase))
    return img, None


def draw_frame(t):
    scene = next(s for s in SCENES if s[1] <= t < s[2])[0] if t < DUR else "light"
    img = ROOM.copy()

    # Bulb state
    if scene in ("music", "drop"):
        b = int(t / BEAT)
        bar = b // 4
        since = t - b * BEAT
        if scene == "drop":
            half = int(t / (BEAT / 2))
            white = half % 2 == 0
            col = np.array([1, 1, 1.0]) if white else hsv(NEON[(bar + half) % 6])
            inten = 1.0 if (t % (BEAT / 2)) < 0.11 else 0.25
        else:
            col = hsv(NEON[bar % 6])
            pos = b % 4
            inten = (1.0 if pos == 0 else 0.62) if since < 0.11 else 0.17
        info = "%d BPM, %s" % (BPM, "Groove" if scene == "music" else "Drop")
    elif scene == "screen":
        _, avg = screen_content(t, scene)
        col = avg / max(avg.max(), 1e-3)
        inten = 0.75
        info = "Following display"
    else:
        col = np.array([1.0, 0.78, 0.5])
        inten = 0.8
        info = "Warm white"

    # Light on the wall and ceiling
    img += glow(col, 0.55 * inten, BULB[0], BULB[1] + 40, 330)
    img += glow(col, 0.35 * inten, BULB[0], BULB[1], 120)

    # Monitor screen + its own small glow on the desk
    scr, _ = screen_content(t, scene)
    x0, y0, x1, y1 = MON
    img[y0:y1, x0:x1] = scr
    img += glow(scr.reshape(-1, 3).mean(0), 0.25, (x0 + x1) / 2, y1 + 30, 160)

    im = Image.fromarray((np.clip(img, 0, 1) ** (1 / 1.1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(im)
    # monitor bezel and stand
    d.rounded_rectangle((x0 - 10, y0 - 10, x1 + 10, y1 + 10), 8, outline=(28, 26, 24), width=10)
    d.rectangle(((x0 + x1) // 2 - 14, y1 + 10, (x0 + x1) // 2 + 14, y1 + 40), fill=(30, 28, 26))
    d.rectangle(((x0 + x1) // 2 - 60, y1 + 38, (x0 + x1) // 2 + 60, y1 + 44), fill=(34, 31, 29))
    # desk
    d.rectangle((60, 494, 900, 506), fill=(52, 40, 32))
    d.rectangle((90, 506, 104, 540), fill=(40, 31, 25))
    d.rectangle((856, 506, 870, 540), fill=(40, 31, 25))
    # pendant cord + bulb
    d.line((BULB[0], 0, BULB[0], BULB[1] - 24), fill=(40, 38, 36), width=3)
    d.rectangle((BULB[0] - 9, BULB[1] - 28, BULB[0] + 9, BULB[1] - 14), fill=(55, 52, 48))
    bc = tuple(int(c) for c in np.clip(col * (0.35 + 0.65 * inten) * 255 + 40 * inten, 0, 255))
    d.ellipse((BULB[0] - 18, BULB[1] - 18, BULB[0] + 18, BULB[1] + 18), fill=bc)

    # menu bar strip + popover, like the real app
    d.rectangle((0, 0, W, 22), fill=(24, 22, 21))
    d.text((W - 150, 4), "TuyaGlow", font=f_ui_b, fill=(225, 220, 212))
    pop = (W - 250, 30, W - 16, 132)
    d.rounded_rectangle(pop, 10, fill=(36, 34, 32), outline=(64, 60, 56))
    modes = ["Off", "Light", "Music", "Screen"]
    active = {"music": "Music", "drop": "Music", "screen": "Screen", "light": "Light"}[scene]
    seg_w = (pop[2] - pop[0] - 24) / 4
    for i, m in enumerate(modes):
        sx0 = pop[0] + 12 + i * seg_w
        if m == active:
            d.rounded_rectangle((sx0, 44, sx0 + seg_w - 2, 66), 6, fill=(196, 140, 84))
        d.text((sx0 + seg_w / 2 - d.textlength(m, font=f_ui) / 2, 48), m, font=f_ui, fill=(240, 236, 230) if m == active else (170, 164, 156))
    d.ellipse((pop[0] + 14, 82, pop[0] + 22, 90), fill=(110, 180, 110))
    d.text((pop[0] + 30, 78), "Connected", font=f_ui, fill=(170, 164, 156))
    d.text((pop[0] + 14, 104), info, font=f_ui_b, fill=(232, 226, 218))

    # caption
    caption = {"music": ("Music", "Locks onto the beat. New color every bar."),
               "drop": ("Drop", "Bass slams back in. White strobe for one bar."),
               "screen": ("Screen", "Follows the main color on your display."),
               "light": ("Light", "A normal bulb: whites and any color.")}[scene]
    d.text((40, 40), caption[0], font=f_cap, fill=(236, 230, 222))
    d.text((40, 74), caption[1], font=f_sub, fill=(176, 168, 158))
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        n = int(DUR * FPS)
        for i in range(n):
            draw_frame(i / FPS).save(os.path.join(tmp, "f%04d.png" % i))
        draw_frame(3.0 * BEAT * 4 + 0.02).resize((1200, 675)).crop((0, 22, 1200, 652)).save(os.path.join(OUT, "og-image.png"))
        src = os.path.join(tmp, "f%04d.png")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", src, "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-crf", "22", "-movflags", "+faststart", os.path.join(OUT, "demo.mp4")], check=True)
        pal = os.path.join(tmp, "pal.png")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", src, "-vf",
                        "fps=15,scale=720:-1:flags=lanczos,palettegen=max_colors=128", pal], check=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", src, "-i", pal, "-lavfi",
                        "fps=15,scale=720:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4",
                        os.path.join(OUT, "demo.gif")], check=True)
    for f in ("demo.mp4", "demo.gif", "og-image.png"):
        print(f, os.path.getsize(os.path.join(OUT, f)) // 1024, "KB")


if __name__ == "__main__":
    main()
