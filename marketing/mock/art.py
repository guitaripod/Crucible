import hashlib
import math
import os
import sys
import time
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import library

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "assets")

FONT_DIRS = ["/usr/share/fonts/noto", "/usr/share/fonts/liberation", "/usr/share/fonts/TTF",
             "/Library/Fonts", "/System/Library/Fonts/Supplemental"]
FONT_FILES = {
    "cond": ("RobotoCondensed-Bold.ttf", 0.16),
    "light": ("Roboto-Light.ttf", 0.34),
    "serif": ("NotoSerifDisplay-Medium.ttf", 0.10),
    "black": ("Roboto-Black.ttf", 0.06),
    "tag": ("NotoSerif-Italic.ttf", 0.02),
    "bill": ("RobotoCondensed-Regular.ttf", 0.14),
    "bold": ("Roboto-Bold.ttf", 0.0),
    "medium": ("Roboto-Medium.ttf", 0.0),
}
_font_cache = {}


def font(kind, size):
    key = (kind, int(size))
    if key not in _font_cache:
        name = FONT_FILES[kind][0]
        for d in FONT_DIRS:
            p = os.path.join(d, name)
            if os.path.exists(p):
                _font_cache[key] = ImageFont.truetype(p, int(size))
                break
        else:
            _font_cache[key] = ImageFont.load_default()
    return _font_cache[key]


def hexc(h):
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5)], np.float32)


def pal(sky, glow, dark, accent=None):
    s = [hexc(c) for c in sky]
    return {"sky": s, "glow": hexc(glow), "dark": hexc(dark), "haze": s[3] * 0.85 + hexc(glow) * 0.15,
            "accent": hexc(accent or glow)}


PALETTES = {
    "teal_amber": pal(["#030f17", "#0a3640", "#2a7c80", "#f0b062"], "#ffc274", "#02090d", "#ff9a3c"),
    "crimson_night": pal(["#0b0408", "#3a0b1c", "#8c1f2e", "#ff7a45"], "#ff9a5a", "#080206"),
    "ice_blue": pal(["#06121f", "#17385e", "#5b8fba", "#d7ecf7"], "#e8f6ff", "#050c14", "#9fd8ff"),
    "violet_neon": pal(["#0a0418", "#2a0f55", "#7a2a9a", "#ff5fa8"], "#ff6fb5", "#05020d", "#46e6ff"),
    "desert_gold": pal(["#1c0d08", "#6b2d14", "#d2682a", "#ffd089"], "#ffe0a0", "#1a0a05"),
    "forest_green": pal(["#04100c", "#0f3a2c", "#3f8a5c", "#d6e8a0"], "#e9f3b0", "#030b08"),
    "mono_noir": pal(["#050505", "#1c1f24", "#4a5058", "#b9bec6"], "#e6eaf0", "#020203"),
    "sunset_pink": pal(["#140a24", "#4b1e5c", "#c8435f", "#ffb468"], "#ffc080", "#0a0414", "#ff8ac0"),
    "ocean_deep": pal(["#020a18", "#06264a", "#0d5f8c", "#6ed0d6"], "#9be8e0", "#01060f"),
    "ember": pal(["#0c0502", "#4a1606", "#b83d0c", "#ffb22e"], "#ffc24a", "#080301"),
    "olive_haze": pal(["#0c0e06", "#34391a", "#7d8040", "#e8d79a"], "#f0e3a8", "#070803"),
    "indigo_dawn": pal(["#070a24", "#1b2a6b", "#5a6fc0", "#ffc9a0"], "#ffd8b8", "#040618", "#8fb0ff"),
    "rust_dust": pal(["#140b08", "#4a2a22", "#9a5a40", "#e8b98c"], "#f0c8a0", "#0d0604"),
    "aqua_mint": pal(["#02141a", "#0a4a52", "#2fb0a8", "#f0f5c0"], "#f4f8c8", "#010c0f"),
}

SKY_POS = np.array([0.0, 0.45, 0.8, 1.0], np.float32)


def seed_of(*parts):
    return int.from_bytes(hashlib.sha256("|".join(map(str, parts)).encode()).digest()[:8], "big")


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def blur(a, r):
    if r < 0.5:
        return a
    m = max(1.0, float(a.max()))
    if a.ndim == 2:
        im = Image.fromarray((np.clip(a / m, 0, 1) * 255).astype(np.uint8), "L")
        return np.asarray(im.filter(ImageFilter.GaussianBlur(r)), np.float32) / 255 * m
    im = Image.fromarray((np.clip(a / m, 0, 1) * 255).astype(np.uint8), "RGB")
    return np.asarray(im.filter(ImageFilter.GaussianBlur(r)), np.float32) / 255 * m


def fbm1d(w, rng, octaves=5, base=3, persist=0.5):
    acc = np.zeros(w, np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        n = int(base * 2 ** o) + 2
        g = rng.random(n).astype(np.float32)
        x = np.linspace(0, n - 1, w)
        i = np.floor(x).astype(int).clip(0, n - 2)
        f = (x - i).astype(np.float32)
        f = f * f * (3 - 2 * f)
        acc += (g[i] * (1 - f) + g[i + 1] * f) * amp
        tot += amp
        amp *= persist
    acc /= tot
    return (acc - acc.min()) / (acc.max() - acc.min() + 1e-6)


def fbm2d(h, w, rng, octaves=5, bx=4, by=None, persist=0.5):
    by = by or max(2, round(bx * h / w))
    acc = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        gx, gy = int(bx * 2 ** o) + 1, int(by * 2 ** o) + 1
        g = rng.random((gy, gx)).astype(np.float32)
        acc += np.asarray(Image.fromarray(g, "F").resize((w, h), Image.BICUBIC), np.float32) * amp
        tot += amp
        amp *= persist
    acc /= tot
    return np.clip((acc - acc.min()) / (acc.max() - acc.min() + 1e-6), 0, 1)


class Ctx:
    pass


def make_ctx(w, h, style, mode, variant):
    c = Ctx()
    c.w, c.h, c.mode = w, h, mode
    c.pal_name, c.motif, c.font = style
    c.pal = PALETTES[c.pal_name]
    c.rng = np.random.default_rng(seed_of(style, variant, mode))
    c.img = np.zeros((h, w, 3), np.float32)
    c.xs = np.arange(w, dtype=np.float32)[None, :]
    c.ys = np.arange(h, dtype=np.float32)[:, None]
    c.u = w / 1000.0 if mode == "poster" else w / 1920.0 * 1.25
    r = c.rng
    if mode == "poster":
        c.hy = h * r.uniform(0.50, 0.57)
        c.sx = w * r.uniform(0.30, 0.70)
        c.sy = c.hy - h * r.uniform(0.0, 0.10)
    elif mode == "backdrop":
        c.hy = h * r.uniform(0.60, 0.68)
        c.sx = w * r.uniform(0.58, 0.82)
        c.sy = c.hy - h * r.uniform(0.0, 0.14)
    else:
        c.hy = h * r.uniform(0.50, 0.70)
        c.sx = w * r.uniform(0.2, 0.85)
        c.sy = c.hy - h * r.uniform(0.0, 0.2)
    return c


def blend(img, col, alpha):
    a = alpha[..., None] if alpha.ndim == 2 else alpha
    img *= 1 - a
    img += np.asarray(col, np.float32) * a


def sky(c):
    t = np.clip(np.arange(c.h, dtype=np.float32) / max(c.hy, 1), 0, 1) ** 1.5
    cols = np.array(c.pal["sky"])
    col = np.stack([np.interp(t, SKY_POS, cols[:, k]) for k in range(3)], -1)
    c.img[:] = col[:, None, :]


def glow(c, cx, cy, r, color, k=1.0, sq=1.0):
    d2 = ((c.xs - cx) ** 2 + ((c.ys - cy) / sq) ** 2) / (r * r)
    a = np.exp(-d2 * 2.2) * k
    c.img += np.asarray(color, np.float32) * a[..., None]


def sun(c, r, k=1.0, color=None):
    color = c.pal["glow"] if color is None else color
    d = np.sqrt((c.xs - c.sx) ** 2 + (c.ys - c.sy) ** 2)
    glow(c, c.sx, c.sy, r * 9, color, 0.30 * k, 0.8)
    glow(c, c.sx, c.sy, r * 3.5, color, 0.45 * k)
    glow(c, c.sx, c.sy, r * 1.6, color, 0.65 * k)
    disc = np.clip((r - d) / 2.0 + 0.5, 0, 1)
    blend(c.img, np.minimum(color * 1.25 + 0.15, 1.5), disc)


def clouds(c, y0, y1, strength=0.8, dark=0.55, bands=2):
    h, w = c.h, c.w
    n = fbm2d(h, w, c.rng, octaves=5, bx=3, by=11)
    n2 = fbm2d(h, w, c.rng, octaves=4, bx=5, by=18)
    m = smooth(0.48, 0.78, n * 0.7 + n2 * 0.3)
    yy = c.ys[:, 0]
    vm = smooth(y0, y0 + (y1 - y0) * 0.25, yy) * (1 - smooth(y0 + (y1 - y0) * 0.55, y1, yy))
    m = m * vm[:, None] * strength
    lit = np.exp(-(((c.xs - c.sx) / (c.w * 0.5)) ** 2 + ((c.ys - c.sy) / (c.h * 0.35)) ** 2) * 1.6)
    low = c.img * dark + c.pal["dark"] * (1 - dark) * 0.4
    col = low * (1 - lit[..., None]) + (c.pal["glow"] * 0.95 + c.img * 0.2) * lit[..., None]
    c.img[:] = c.img * (1 - m[..., None]) + col * m[..., None]


def stars(c, n, ymax, size=1.0):
    h, w = c.h, c.w
    layer = np.zeros((h, w), np.float32)
    ys = (c.rng.random(n) ** 1.3 * ymax).astype(int).clip(0, h - 1)
    xs = c.rng.integers(0, w, n)
    br = c.rng.random(n) ** 3 * 0.9 + 0.1
    layer[ys, xs] = br
    big = blur(layer, 0.9 * size) * 5
    c.img += np.minimum(big, 1.4)[..., None] * np.array([0.9, 0.95, 1.0], np.float32)
    k = np.argsort(-br)[: max(3, n // 120)]
    for i in k:
        glow(c, xs[i], ys[i], 14 * c.u * size, c.pal["glow"], 0.35 * br[i])


def ridge_fill(c, ys_top, col, mist_col, mist, span):
    h = c.h
    Y = c.ys
    m = np.clip((Y - ys_top[None, :]) / 1.6 + 0.5, 0, 1)
    depth = np.clip((Y - ys_top[None, :]) / span, 0, 1)
    shade = col[None, None, :] * (1 - mist * depth[..., None]) + mist_col[None, None, :] * mist * depth[..., None]
    c.img[:] = c.img * (1 - m[..., None]) + shade * m[..., None]
    return m


def ridges(c, n, y_far, y_near, amp_far, amp_near, crag=False, base_freq=3, mist=0.6, rim=0.25, darkest=1.0):
    pal_ = c.pal
    tops = []
    for i in range(n):
        t = i / max(n - 1, 1)
        base = y_far + (y_near - y_far) * t ** 1.15
        amp = amp_far + (amp_near - amp_far) * t
        f = fbm1d(c.w, c.rng, octaves=6, base=base_freq + 2 * t)
        if crag:
            f = 1 - np.abs(2 * f - 1)
            f = f ** 0.9
        ys = base - amp * f
        k = 0.5 + 0.5 * t ** 1.1
        col = pal_["haze"] * (1 - k) + pal_["dark"] * k * darkest
        span = max(40.0, (y_near - y_far) / n * 2.6)
        ridge_fill(c, ys, col, pal_["haze"] * (0.55 + 0.25 * t) , mist * (1 - t * 0.8), span)
        rimmask = np.exp(-((c.ys - ys[None, :]) / (2.0 * c.u)) ** 2) * (c.ys >= ys[None, :] - 1)
        c.img += (pal_["glow"] * rim * (1 - t) * 0.6)[None, None, :] * rimmask[..., None]
        tops.append(ys)
    return tops


def fog(c, y, thickness, strength=0.35, color=None):
    color = c.pal["haze"] if color is None else color
    n = fbm2d(c.h, c.w, c.rng, octaves=4, bx=4, by=10)
    yy = np.exp(-((c.ys - y) / thickness) ** 2)
    a = np.clip(yy * (0.35 + n * 1.1) * strength, 0, 1)
    blend(c.img, color, a)


def ocean(c, mirror=True, calm=0.5, sunx=None, tint=0.9):
    h, w = c.h, c.w
    hy = int(c.hy)
    sunx = c.sx if sunx is None else sunx
    below = h - hy
    if below <= 4:
        return
    dy = (c.ys - hy) / max(below, 1)
    dy = np.clip(dy, 0, 1)
    top = c.pal["haze"] * 0.55 + c.pal["sky"][2] * 0.3
    deep = c.pal["dark"] * 1.4 + c.pal["sky"][1] * 0.25
    base = top[None, None, :] * (1 - dy[..., None] ** 0.55) + deep[None, None, :] * dy[..., None] ** 0.55
    base = np.broadcast_to(base, (h, w, 3)).copy()
    if mirror:
        src = c.img[:hy][::-1][:below]
        if src.shape[0] < below:
            pad = np.repeat(src[-1:], below - src.shape[0], 0)
            src = np.concatenate([src, pad], 0)
        src = blur(src.copy(), 2.0 * c.u)
        base[hy:hy + below] = base[hy:hy + below] * (1 - 0.55 * tint) + src * 0.55 * tint
    mask = (c.ys >= hy).astype(np.float32)
    rip = np.zeros((h, w), np.float32)
    for dens, amp in ((1.0, 0.6), (2.4, 0.4)):
        rows = max(8, int(below / (4 * c.u) * dens))
        g = c.rng.random((rows, 7)).astype(np.float32)
        layer = np.asarray(Image.fromarray(g, "F").resize((w, below), Image.BICUBIC), np.float32)
        rip[hy:hy + below] += layer * amp
    rip = (rip - 0.5)
    c.img[:] = c.img * (1 - mask[..., None]) + base * mask[..., None]
    spread = (c.w * 0.012 * (1 + 7 * dy)) * (1.2 - calm)
    col = np.exp(-((c.xs - sunx) / spread) ** 2)
    fade = (1 - dy ** 0.7) * smooth(0, 0.03, dy)
    streak = np.clip(0.55 + rip * (3.0 - 2.0 * calm), 0, 1.4) ** 1.5
    refl = col * fade * streak * mask
    c.img += c.pal["glow"][None, None, :] * (refl[..., None] * 0.9)
    wide = np.exp(-((c.xs - sunx) / (c.w * 0.22)) ** 2) * fade * mask * 0.15
    c.img += c.pal["glow"][None, None, :] * wide[..., None]
    hl = np.exp(-((c.ys - hy) / (2.5 * c.u)) ** 2)
    c.img += (c.pal["glow"] * 0.5)[None, None, :] * (hl * np.clip(0.4 + c.xs * 0 + np.exp(-((c.xs - sunx) / (c.w * 0.4)) ** 2), 0, 1))[..., None] * 0.7


def poly_mask(c, polys, scale=1):
    im = Image.new("L", (c.w * scale, c.h * scale), 0)
    d = ImageDraw.Draw(im)
    for p in polys:
        d.polygon([(x * scale, y * scale) for x, y in p], fill=255)
    if scale > 1:
        im = im.resize((c.w, c.h), Image.LANCZOS)
    return np.asarray(im, np.float32) / 255


def rect_mask(c, rects, scale=1):
    im = Image.new("L", (c.w * scale, c.h * scale), 0)
    d = ImageDraw.Draw(im)
    for (x0, y0, x1, y1) in rects:
        d.rectangle([x0 * scale, y0 * scale, x1 * scale, y1 * scale], fill=255)
    if scale > 1:
        im = im.resize((c.w, c.h), Image.LANCZOS)
    return np.asarray(im, np.float32) / 255


def silhouette(c, mask, strength=1.0, tone=None):
    tone = c.pal["dark"] if tone is None else tone
    blend(c.img, tone, mask * strength)


def reflect_mask(c, mask, y_axis, alpha=0.5, blur_r=3):
    h = c.h
    below = h - int(y_axis)
    if below <= 0:
        return
    src = mask[max(0, int(y_axis) - below):int(y_axis)][::-1]
    if src.shape[0] < below:
        src = np.pad(src, ((0, below - src.shape[0]), (0, 0)))
    refl = np.zeros_like(mask)
    refl[int(y_axis):int(y_axis) + below] = src
    refl = blur(refl, blur_r * c.u)
    fade = np.clip(1 - (c.ys - y_axis) / max(below * 0.9, 1), 0, 1)
    silhouette(c, refl * fade * alpha)


def sky_scene(c, star_n=0, cloudy=0.8):
    sky(c)
    if star_n:
        stars(c, star_n, c.hy * 0.8)
    if cloudy:
        clouds(c, c.hy * 0.05, c.hy * 0.98, cloudy)


def line_mask(c, lines, width, scale=2):
    im = Image.new("L", (c.w * scale, c.h * scale), 0)
    d = ImageDraw.Draw(im)
    for (x0, y0, x1, y1) in lines:
        d.line([(x0 * scale, y0 * scale), (x1 * scale, y1 * scale)], fill=255, width=max(1, int(width * scale)))
    return np.asarray(im.resize((c.w, c.h), Image.LANCZOS), np.float32) / 255


def draw_platform(c):
    w, h, u = c.w, c.h, c.u
    hy = c.hy
    cx = c.sx + c.rng.uniform(-0.03, 0.03) * w
    s = (0.50 if c.mode == "poster" else 0.26) * w
    deck_y = hy - s * 0.20
    deck_h = s * 0.05
    rects, polys, lines = [], [], []
    rects.append((cx - s * 0.5, deck_y, cx + s * 0.5, deck_y + deck_h))
    rects.append((cx - s * 0.46, deck_y + deck_h, cx + s * 0.46, deck_y + deck_h * 1.7))
    legs = (-0.40, -0.14, 0.14, 0.40)
    for lx in legs:
        rects.append((cx + lx * s - s * 0.014, deck_y + deck_h, cx + lx * s + s * 0.014, hy + s * 0.012))
    for a_, b_ in zip(legs[:-1], legs[1:]):
        for yf in (0.35, 0.70):
            y0 = deck_y + deck_h + (hy - deck_y - deck_h) * (yf - 0.35)
            y1 = deck_y + deck_h + (hy - deck_y - deck_h) * yf
            lines.append((cx + a_ * s, y0, cx + b_ * s, y1))
            lines.append((cx + b_ * s, y0, cx + a_ * s, y1))
    for yf in (0.35, 0.7):
        yy = deck_y + deck_h + (hy - deck_y - deck_h) * yf
        lines.append((cx - 0.40 * s, yy, cx + 0.40 * s, yy))
    mods = [(-0.44, 0.13, 0.05), (-0.28, 0.20, 0.08), (-0.04, 0.17, 0.12), (0.17, 0.22, 0.06), (0.32, 0.13, 0.09)]
    for off, wd, hh in mods:
        rects.append((cx + off * s, deck_y - hh * s, cx + (off + wd) * s, deck_y))
    rects.append((cx - 0.02 * s, deck_y - 0.20 * s, cx + 0.10 * s, deck_y - 0.12 * s))
    rects.append((cx + 0.28 * s, deck_y - 0.30 * s, cx + 0.285 * s, deck_y - 0.06 * s))
    polys.append([(cx + 0.29 * s, deck_y - 0.22 * s), (cx + 0.70 * s, deck_y - 0.42 * s), (cx + 0.705 * s, deck_y - 0.415 * s), (cx + 0.30 * s, deck_y - 0.21 * s)])
    polys.append([(cx + 0.34 * s, deck_y - 0.06 * s), (cx + 0.48 * s, deck_y - 0.30 * s), (cx + 0.485 * s, deck_y - 0.298 * s), (cx + 0.35 * s, deck_y - 0.06 * s)])
    polys.append([(cx - 0.30 * s, deck_y - 0.08 * s), (cx - 0.26 * s, deck_y - 0.40 * s), (cx - 0.252 * s, deck_y - 0.40 * s), (cx - 0.292 * s, deck_y - 0.08 * s)])
    polys.append([(cx - 0.50 * s, deck_y - 0.01 * s), (cx - 0.70 * s, deck_y - 0.06 * s), (cx - 0.70 * s, deck_y - 0.02 * s), (cx - 0.50 * s, deck_y + 0.015 * s)])
    polys.append([(cx - 0.50 * s, deck_y + 0.01 * s), (cx - 0.60 * s, deck_y + 0.01 * s), (cx - 0.48 * s, deck_y + 0.07 * s)])
    m = np.maximum.reduce([rect_mask(c, rects, 2), poly_mask(c, polys, 2), line_mask(c, lines, max(1.4, s * 0.004))])
    lit = []
    for i in range(26):
        off, wd, hh = mods[i % len(mods)]
        lx = cx + (off + 0.015 + (i // len(mods)) * 0.025) * s
        ly = deck_y - hh * s * (0.25 + 0.4 * ((i * 7) % 3) / 2)
        if (i * 5) % 4 != 0:
            lit.append((lx, ly, lx + s * 0.011, ly + s * 0.014))
    lit.append((cx + 0.70 * s, deck_y - 0.43 * s, cx + 0.712 * s, deck_y - 0.418 * s))
    lit.append((cx - 0.256 * s, deck_y - 0.41 * s, cx - 0.248 * s, deck_y - 0.40 * s))
    for k in range(10):
        lx = cx + (-0.48 + k * 0.1) * s
        lit.append((lx, deck_y + deck_h * 1.2, lx + s * 0.008, deck_y + deck_h * 1.5))
    lm = rect_mask(c, lit, 2)
    silhouette(c, m, 0.98)
    reflect_mask(c, m, hy, 0.5, 4)
    c.img += (c.pal["accent"] * 1.25)[None, None, :] * lm[..., None]
    c.img += (c.pal["accent"] * 0.8)[None, None, :] * (blur(lm, 5 * u) * 2.8)[..., None]
    glow(c, cx + 0.48 * s, deck_y - 0.31 * s, s * 0.06, c.pal["accent"], 0.9)


def draw_lighthouse(c):
    w, h, u = c.w, c.h, c.u
    hy = c.hy
    left = c.sx > w * 0.5
    rx = w * (0.26 if left else 0.74)
    rs = w * (0.55 if c.mode == "poster" else 0.30)
    x = np.arange(w)
    rock_f = fbm1d(w, c.rng, 6, 5)
    dist = np.abs(x - rx) / (rs * 0.5)
    prof = np.clip(1 - dist ** 1.4, 0, 1) ** 1.2
    water = hy + h * 0.018
    peak = h * (0.075 if c.mode == "poster" else 0.10)
    rock_top = np.where(prof > 0, water - prof * peak * (0.55 + rock_f * 0.9), h + 50)
    m_rock = np.clip((c.ys - rock_top[None, :]) / 1.5 + 0.5, 0, 1) * (c.ys <= water + 2)
    tx = rx
    tb_y = float(np.min(rock_top[int(max(0, tx - 8)):int(min(w, tx + 8))])) + 6
    tower_h = h * (0.27 if c.mode == "poster" else 0.38)
    tw0, tw1 = tower_h * 0.085, tower_h * 0.048
    top_y = tb_y - tower_h
    g = tower_h * 0.02
    polys = [[(tx - tw0, tb_y), (tx - tw1, top_y), (tx + tw1, top_y), (tx + tw0, tb_y)],
             [(tx - tw1 * 1.7, top_y), (tx + tw1 * 1.7, top_y), (tx + tw1 * 1.7, top_y - g), (tx - tw1 * 1.7, top_y - g)],
             [(tx - tw1 * 1.15, top_y - g), (tx + tw1 * 1.15, top_y - g), (tx + tw1 * 1.15, top_y - g - tower_h * 0.06), (tx - tw1 * 1.15, top_y - g - tower_h * 0.06)],
             [(tx - tw1 * 1.5, top_y - g - tower_h * 0.06), (tx + tw1 * 1.5, top_y - g - tower_h * 0.06), (tx, top_y - g - tower_h * 0.135)]]
    mt = poly_mask(c, polys, 2)
    ly = top_y - g - tower_h * 0.03
    direction = 1 if tx < w * 0.5 else -1
    scale = 4
    sm = Image.new("L", (w // scale, h // scale), 0)
    d = ImageDraw.Draw(sm)
    L = w * 1.2
    spread = h * 0.045
    d.polygon([(tx / scale, ly / scale), ((tx + direction * L) / scale, (ly - spread) / scale), ((tx + direction * L) / scale, (ly + spread * 2.2) / scale)], fill=255)
    beam = np.asarray(sm.filter(ImageFilter.GaussianBlur(3)).resize((w, h), Image.BICUBIC), np.float32) / 255
    falloff = np.clip(1 - np.abs(c.xs - tx) / L, 0, 1) ** 1.1
    c.img += c.pal["glow"][None, None, :] * (beam * falloff * 0.8)[..., None]
    glow(c, tx, ly, 90 * u, c.pal["glow"], 0.9)
    allm = np.maximum(mt, m_rock)
    silhouette(c, allm, 0.98)
    c.img += (c.pal["glow"] * 1.5)[None, None, :] * rect_mask(c, [(tx - tw1 * 0.9, ly - tower_h * 0.016, tx + tw1 * 0.9, ly + tower_h * 0.016)], 2)[..., None]
    reflect_mask(c, allm, water, 0.5, 5)


def draw_ship(c, x=None, scale=None, ymul=1.0):
    w, h, u = c.w, c.h, c.u
    hy = c.hy
    x = (c.sx * 0.5 + w * 0.15) if x is None else x
    s = (0.30 if c.mode == "poster" else 0.18) * w if scale is None else scale
    y = hy + s * 0.03 * ymul
    hull = [(x - s * 0.5, y - s * 0.07), (x + s * 0.5, y - s * 0.09), (x + s * 0.44, y), (x - s * 0.42, y)]
    parts = [hull,
             [(x - s * 0.28, y - s * 0.07), (x - s * 0.28, y - s * 0.17), (x + s * 0.12, y - s * 0.17), (x + s * 0.12, y - s * 0.07)],
             [(x - s * 0.2, y - s * 0.17), (x - s * 0.2, y - s * 0.24), (x + s * 0.02, y - s * 0.24), (x + s * 0.02, y - s * 0.17)],
             [(x - s * 0.1, y - s * 0.24), (x - s * 0.1, y - s * 0.30), (x - s * 0.03, y - s * 0.30), (x - s * 0.03, y - s * 0.24)],
             [(x + s * 0.28, y - s * 0.09), (x + s * 0.285, y - s * 0.34), (x + s * 0.295, y - s * 0.34), (x + s * 0.30, y - s * 0.09)],
             [(x - s * 0.40, y - s * 0.07), (x - s * 0.395, y - s * 0.28), (x - s * 0.385, y - s * 0.28), (x - s * 0.38, y - s * 0.07)]]
    m = poly_mask(c, parts, 2)
    silhouette(c, m, 0.97)
    reflect_mask(c, m, y, 0.5, 3)
    lights = [(x - s * 0.24 + i * s * 0.05, y - s * 0.13, x - s * 0.24 + i * s * 0.05 + s * 0.012, y - s * 0.12) for i in range(6)]
    lights += [(x + s * 0.285, y - s * 0.35, x + s * 0.295, y - s * 0.34)]
    lm = rect_mask(c, lights, 2)
    c.img += (c.pal["accent"] * 1.3)[None, None, :] * lm[..., None]
    c.img += (c.pal["accent"] * 0.7)[None, None, :] * (blur(lm, 4 * u) * 3)[..., None]


def draw_city(c, layers=3, windows=True, neon=True, street=True, ground=None):
    w, h, u = c.w, c.h, c.u
    gy = c.hy + (h - c.hy) * (0.35 if street else 0.0) if ground is None else ground
    glowlayer = np.zeros((h, w, 3), np.float32)
    winlayer = np.zeros((h, w), np.float32)
    for li in range(layers):
        t = li / max(layers - 1, 1)
        bw_lo, bw_hi = (14 + 10 * t) * u, (34 + 40 * t) * u
        top_lo, top_hi = (0.12 + 0.12 * t) * h, (0.30 + 0.30 * t) * h
        x = -c.rng.uniform(0, 40) * u
        rects = []
        wins = []
        base_y = gy + (1 - t) * (-h * 0.0) - (layers - 1 - li) * 0
        while x < w:
            bw = c.rng.uniform(bw_lo, bw_hi)
            bh = c.rng.uniform(top_lo, top_hi) * (0.45 + c.rng.random() ** 2 * 1.1)
            rects.append((x, base_y - bh, x + bw, base_y + 4))
            if li >= 1 and windows:
                cell_w, cell_h = 7 * u, 11 * u
                cols = int(bw / cell_w) - 1
                rows = int(bh / cell_h) - 1
                on = 0.07 + 0.07 * t
                for r_ in range(rows):
                    for c_ in range(cols):
                        if c.rng.random() < on:
                            wx = x + (c_ + 0.5) * cell_w + 1
                            wy = base_y - bh + (r_ + 0.7) * cell_h
                            wins.append((wx, wy, wx + 3.2 * u, wy + 4.2 * u))
            if neon and li == layers - 1 and c.rng.random() < 0.18:
                col = c.pal["accent"] if c.rng.random() < 0.5 else c.pal["sky"][2] * 1.5
                nx = x + bw * 0.5
                ex = (nx, base_y - bh + 2, nx + 2.5 * u, base_y - bh * c.rng.uniform(0.3, 0.8))
                im = Image.new("L", (w, h), 0)
                ImageDraw.Draw(im).rectangle(ex, fill=255)
                glowlayer += np.asarray(im, np.float32)[..., None] / 255 * np.asarray(col, np.float32) * 1.5
            x += bw + c.rng.uniform(0, 6) * u
        m = rect_mask(c, rects)
        k = 0.30 + 0.7 * t ** 0.9
        col = c.pal["haze"] * (1 - k) * 0.7 + c.pal["dark"] * k
        blend(c.img, col, m)
        if wins:
            winlayer = np.maximum(winlayer, rect_mask(c, wins))
        if li == layers - 1:
            c.near_mask = m
    wcol = c.pal["glow"] * 0.9 + c.pal["accent"] * 0.3
    c.img += wcol[None, None, :] * (winlayer * 0.9)[..., None]
    c.img += wcol[None, None, :] * (blur(winlayer, 6 * u) * 1.6)[..., None]
    if neon:
        c.img += blur(glowlayer, 5 * u) * 2.2 + glowlayer * 0.8
    if street:
        yy = (c.ys - gy)
        gmask = np.clip(yy / 2 + 0.5, 0, 1)
        gcol = c.pal["dark"] * 1.5 + c.pal["sky"][1] * 0.25
        blend(c.img, gcol, gmask * np.ones((1, w), np.float32))
        refl = c.img[:int(gy)][::-1]
        below = h - int(gy)
        refl = refl[:below]
        if refl.shape[0] < below:
            refl = np.concatenate([refl, np.repeat(refl[-1:], below - refl.shape[0], 0)], 0)
        refl = blur(refl.copy(), 3 * u)
        fade = np.clip(1 - np.arange(below)[:, None, None] / (below * 0.85), 0, 1) ** 1.4
        c.img[int(gy):] = c.img[int(gy):] * (1 - 0.55 * fade) + refl * 0.55 * fade


def draw_pines(c, base_ys, density=1.0, hmin=0.05, hmax=0.14, tone=None, left_right=False):
    w, h, u = c.w, c.h, c.u
    im = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(im)
    x = 0.0
    step = 9 * u / density
    while x < w:
        base = float(base_ys[int(min(w - 1, x))]) + 4
        th = c.rng.uniform(hmin, hmax) * h
        tw = th * 0.28
        tiers = 6
        for t in range(tiers):
            f0, f1 = t / tiers, (t + 1) / tiers
            ty0 = base - th * (1 - f0 * 0.85 + 0.0) + th * 0.0
            yb = base - th * f0
            yt = base - th * min(1, f1 + 0.22)
            wid = tw * (1 - f0 * 0.8)
            d.polygon([(x - wid, yb), (x + wid, yb), (x, yt)], fill=255)
        d.rectangle([x - 1.2 * u, base - th * 0.05, x + 1.2 * u, base + 8], fill=255)
        x += step * c.rng.uniform(0.6, 1.5)
    m = np.asarray(im.filter(ImageFilter.GaussianBlur(0.6)), np.float32) / 255
    silhouette(c, m, 1.0, tone)
    return m


def draw_snow(c, n=900, wind=0.25):
    w, h, u = c.w, c.h, c.u
    for size, cnt, alpha, bl in ((1.2, n, 0.5, 0.5), (2.6, n // 4, 0.55, 1.2), (6.0, n // 14, 0.45, 3.0), (14.0, 6, 0.3, 8.0)):
        im = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(im)
        for _ in range(cnt):
            x, y = c.rng.uniform(0, w), c.rng.uniform(0, h)
            r = size * u * c.rng.uniform(0.6, 1.3)
            d.ellipse([x - r, y - r, x + r, y + r], fill=int(255 * c.rng.uniform(0.4, 1)))
        a = blur(np.asarray(im, np.float32) / 255, bl * u) * alpha * 1.6
        c.img += np.minimum(a, 1)[..., None] * (c.pal["glow"] * 0.9 + 0.1)[None, None, :]


def draw_rain(c, n=900, alpha=0.22):
    w, h, u = c.w, c.h, c.u
    im = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(im)
    for _ in range(n):
        x, y = c.rng.uniform(-50, w), c.rng.uniform(-50, h)
        ln = c.rng.uniform(25, 70) * u
        d.line([(x, y), (x - ln * 0.18, y + ln)], fill=int(255 * c.rng.uniform(0.3, 1)), width=max(1, int(1.2 * u)))
    a = np.asarray(im, np.float32) / 255
    c.img += (a * alpha)[..., None] * (c.pal["glow"] * 0.8 + 0.2)[None, None, :]


def draw_planet(c):
    w, h = c.w, c.h
    R = w * (1.6 if c.mode == "poster" else 1.1)
    cx = w * c.rng.uniform(0.35, 0.65)
    cy = h + R * 0.78 - h * (0.20 if c.mode == "poster" else 0.18)
    d = np.sqrt((c.xs - cx) ** 2 + (c.ys - cy) ** 2)
    body = np.clip((R - d) / 2.0 + 0.5, 0, 1)
    rim = np.exp(-((d - R) / (R * 0.012)) ** 2)
    atmos = np.exp(-np.clip(d - R, 0, None) / (R * 0.05)) * (d > R - 1)
    surf = c.pal["dark"] * 1.2 + c.pal["sky"][1] * 0.2
    blend(c.img, surf, body)
    c.img += (c.pal["glow"] * 1.3)[None, None, :] * (rim * 0.9)[..., None]
    c.img += (c.pal["sky"][2] * 1.2)[None, None, :] * (atmos * 0.45)[..., None]
    lit = np.exp(-((c.xs - c.sx) / (w * 0.35)) ** 2)
    c.img += (c.pal["accent"] * 0.8)[None, None, :] * (rim * lit * 1.5)[..., None]


def draw_nebula(c):
    h, w = c.h, c.w
    n1 = fbm2d(h, w, c.rng, 6, bx=3, by=max(3, round(3 * h / w)))
    n2 = fbm2d(h, w, c.rng, 6, bx=4, by=max(4, round(4 * h / w)))
    n3 = fbm2d(h, w, c.rng, 5, bx=6, by=max(6, round(6 * h / w)))
    s = c.pal["sky"]
    f = smooth(0.35, 0.8, n1)
    g = smooth(0.4, 0.85, n2) * 0.8
    base = s[1] * 0.45
    img = np.broadcast_to(c.pal["dark"] * 1.6, (h, w, 3)).copy()
    img += (base[None, None, :]) * f[..., None] * 1.3
    img += (s[2] * 0.9)[None, None, :] * (g * f)[..., None] * 0.9
    img += (c.pal["accent"] * 0.7)[None, None, :] * (smooth(0.55, 0.9, n3) * f)[..., None] * 0.55
    dark = smooth(0.55, 0.9, fbm2d(h, w, c.rng, 5, bx=3, by=max(3, round(3 * h / w))))
    img *= (1 - 0.7 * dark)[..., None]
    c.img[:] = img
    glow(c, c.sx, c.sy * 0.7, h * 0.35, c.pal["glow"], 0.45, 0.8)
    glow(c, c.sx, c.sy * 0.7, h * 0.08, c.pal["glow"] * 1.2, 0.7)
    stars(c, int(w * h / 900), h)


def draw_dunes(c, n=5):
    w, h, u = c.w, c.h, c.u
    for i in range(n):
        t = i / max(n - 1, 1)
        base = c.hy + (h - c.hy) * (0.05 + 0.85 * t ** 1.3) + 10
        amp = h * (0.05 + 0.10 * t)
        f = fbm1d(w, c.rng, 4, 2 + t * 1.5)
        ys = base - amp * (f ** 1.2) * 1.2
        k = 0.2 + 0.7 * t
        col = c.pal["haze"] * (1 - k) * 0.9 + c.pal["dark"] * k * 1.1
        m = ridge_fill(c, ys, col, c.pal["haze"] * 0.7, 0.5 * (1 - t), max(60.0, (h - c.hy) * 0.25))
        slope = np.gradient(ys)
        sunside = np.clip(-np.sign(c.sx - w / 2) * slope * 0.8, 0, 1)
        band = np.exp(-((c.ys - ys[None, :]) / (9 * u * (0.6 + t))) ** 2) * (c.ys >= ys[None, :])
        c.img += (c.pal["glow"] * 0.45 * (1 - 0.5 * t))[None, None, :] * (band * (0.25 + sunside[None, :]))[..., None]


def draw_hills(c, n=5):
    w, h = c.w, c.h
    tops = ridges(c, n, c.hy - h * 0.06, h * 0.93, h * 0.06, h * 0.10, crag=False, base_freq=2, mist=0.55, rim=0.35)
    return tops


def draw_road(c, rails=False):
    w, h, u = c.w, c.h, c.u
    vx = c.sx + c.rng.uniform(-0.1, 0.1) * w
    vy = c.hy
    half = w * 0.55
    ground = c.pal["dark"] * 1.4 + c.pal["sky"][1] * 0.2
    gm = (c.ys >= vy).astype(np.float32)
    blend(c.img, ground * 0.9 + c.pal["haze"] * 0.1, gm * np.ones((1, w), np.float32))
    road_poly = [(vx - 6 * u, vy), (vx + 6 * u, vy), (vx + half * (1 + 0.1), h + 2), (vx - half * (1 - 0.1), h + 2)]
    m = poly_mask(c, [road_poly], 2)
    blend(c.img, c.pal["dark"] * 0.9 + c.pal["haze"] * 0.12, m)
    reflect_amt = np.exp(-((c.xs - vx) / (w * 0.25)) ** 2) * np.clip((c.ys - vy) / (h - vy), 0, 1) ** 1.3 * (c.ys >= vy)
    c.img += (c.pal["glow"] * 0.35)[None, None, :] * (reflect_amt * m * 0.8)[..., None]
    if rails:
        for off in (-0.16, 0.16):
            poly = [(vx + off * 12 * u, vy), (vx + off * 12 * u + 1.5 * u, vy),
                    (vx + off * w * 1.0 + 6 * u, h + 2), (vx + off * w * 1.0 - 6 * u, h + 2)]
            pm = poly_mask(c, [poly], 2)
            c.img += (c.pal["glow"] * 0.55)[None, None, :] * (pm * 0.8)[..., None]
        rows = []
        for k in range(1, 40):
            t = (k / 40) ** 2.2
            y = vy + (h - vy) * t
            hw = 0.19 * w * t * 1.15 + 8 * u
            rows.append((vx - hw, y, vx + hw, y + max(1.0, 7 * u * t)))
        sm = rect_mask(c, rows)
        blend(c.img, c.pal["dark"] * 0.5, sm * 0.8)
    else:
        dashes = []
        for k in range(1, 26):
            t0, t1 = (k / 26) ** 2.1, ((k + 0.45) / 26) ** 2.1
            y0, y1 = vy + (h - vy) * t0, vy + (h - vy) * t1
            wd = 1 + 7 * u * t0 * 2
            dashes.append([(vx - wd * 0.5, y0), (vx + wd * 0.5, y0), (vx + wd * 0.9, y1), (vx - wd * 0.9, y1)])
        dm = poly_mask(c, dashes, 1)
        c.img += (c.pal["glow"] * 0.9)[None, None, :] * (dm * 0.8)[..., None]
        c.img += (c.pal["glow"] * 0.4)[None, None, :] * blur(dm, 3 * u)[..., None]
    sun(c, 22 * c.u, 0.8)
    for side in (-1, 1):
        poles = []
        for k in range(1, 12):
            t = (k / 12) ** 2.0
            y = vy + (h - vy) * t
            x = vx + side * (0.2 * w * t * 1.25 + 15 * u)
            ph = (h * 0.28) * t + 3
            poles.append((x - 1.5 * u * (0.5 + 4 * t), y - ph, x + 1.5 * u * (0.5 + 4 * t), y))
        silhouette(c, rect_mask(c, poles), 0.95)


def render_scene(w, h, style, mode, variant=0):
    c = make_ctx(w, h, style, mode, variant)
    motif = c.motif
    P = c.pal
    stary = motif in ("nebula",)
    if motif == "nebula":
        draw_nebula(c)
        if mode != "still" or variant % 2 == 0:
            draw_planet(c)
    elif motif == "platform":
        sky_scene(c, 0, 0.9)
        sun(c, 34 * c.u, 1.0)
        ocean(c, True, 0.4)
        draw_platform(c)
        fog(c, c.hy, c.h * 0.05, 0.5)
    elif motif == "lighthouse":
        sky_scene(c, 0, 1.0)
        sun(c, 30 * c.u, 0.9)
        ocean(c, True, 0.2)
        draw_lighthouse(c)
        fog(c, c.hy, c.h * 0.05, 0.4)
    elif motif == "ocean":
        sky_scene(c, 0, 1.0)
        sun(c, 36 * c.u, 1.0)
        ocean(c, True, 0.25)
        draw_ship(c, x=c.w * c.rng.uniform(0.2, 0.8), scale=c.w * 0.07)
        fog(c, c.hy, c.h * 0.04, 0.5)
    elif motif == "ship":
        sky_scene(c, 0, 0.9)
        sun(c, 30 * c.u, 1.0)
        ocean(c, True, 0.35)
        draw_ship(c)
        fog(c, c.hy, c.h * 0.04, 0.4)
    elif motif in ("mirror", "lake"):
        sky_scene(c, 0, 0.8)
        sun(c, 30 * c.u, 0.9)
        ridges(c, 4 if motif == "mirror" else 3, c.hy - c.h * 0.12, c.hy, c.h * 0.10, c.h * 0.04, True, 3, 0.7, 0.2)
        ocean(c, True, 0.7, tint=1.0)
        fog(c, c.hy, c.h * 0.035, 0.45)
    elif motif == "snowpeaks":
        sky_scene(c, 0, 0.6)
        sun(c, 26 * c.u, 0.8)
        ridges(c, 5, c.hy - c.h * 0.05, c.h * 0.95, c.h * 0.26, c.h * 0.18, True, 2, 0.75, 0.5, 0.9)
        draw_snow(c, int(1400 * c.u))
    elif motif == "dunes":
        sky_scene(c, 0, 0.7)
        sun(c, 40 * c.u, 1.0)
        draw_dunes(c, 5)
        fog(c, c.hy, c.h * 0.04, 0.25)
    elif motif == "hills":
        sky_scene(c, 0, 0.8)
        stars(c, int(c.w * c.h / 5000), c.hy * 0.5)
        sun(c, 42 * c.u, 0.9)
        draw_hills(c, 5)
        fog(c, c.hy + c.h * 0.05, c.h * 0.05, 0.35)
        for _ in range(26):
            x, y = c.rng.uniform(0, c.w), c.rng.uniform(c.hy * 0.5, c.h * 0.9)
            glow(c, x, y, c.rng.uniform(8, 24) * c.u, c.pal["accent"], 0.7)
    elif motif == "river":
        sky_scene(c, 0, 0.7)
        sun(c, 30 * c.u, 0.9)
        tops = ridges(c, 4, c.hy - c.h * 0.10, c.hy + c.h * 0.03, c.h * 0.12, c.h * 0.05, False, 3, 0.7, 0.2)
        draw_pines(c, tops[-1], 1.0, 0.03, 0.07)
        ocean(c, True, 0.8, tint=1.0)
        for _ in range(20):
            x, y = c.rng.uniform(0, c.w), c.rng.uniform(c.hy + 20, c.h * 0.95)
            glow(c, x, y, c.rng.uniform(5, 14) * c.u, c.pal["accent"], 0.55)
    elif motif == "forest":
        sky_scene(c, 0, 0.7)
        sun(c, 34 * c.u, 0.9)
        tops = ridges(c, 4, c.hy - c.h * 0.08, c.h * 0.78, c.h * 0.16, c.h * 0.10, True, 3, 0.8, 0.35)
        fog(c, c.hy + c.h * 0.05, c.h * 0.06, 0.5)
        near = tops[-1] + c.h * 0.0
        draw_pines(c, tops[-2], 1.1, 0.06, 0.15, tone=P["dark"] * 1.2)
        draw_pines(c, near, 0.9, 0.12, 0.27, tone=P["dark"])
        fog(c, c.hy + c.h * 0.10, c.h * 0.05, 0.25)
    elif motif == "rails":
        sky_scene(c, 0, 0.8)
        sun(c, 36 * c.u, 1.0)
        ridges(c, 3, c.hy - c.h * 0.10, c.hy, c.h * 0.08, c.h * 0.04, False, 3, 0.7, 0.2)
        draw_road(c, rails=True)
        fog(c, c.hy, c.h * 0.03, 0.45)
    elif motif == "road":
        sky_scene(c, 0, 0.6)
        ridges(c, 4, c.hy - c.h * 0.10, c.hy + 2, c.h * 0.14, c.h * 0.04, True, 3, 0.75, 0.3)
        draw_road(c, rails=False)
        draw_snow(c, int(900 * c.u))
        fog(c, c.hy, c.h * 0.03, 0.5)
    elif motif == "harbour":
        sky_scene(c, 0, 0.9)
        sun(c, 30 * c.u, 0.9)
        ocean(c, True, 0.4)
        draw_city(c, 2, True, False, False, ground=c.hy)
        draw_ship(c, x=c.w * c.rng.uniform(0.2, 0.45), scale=c.w * 0.26)
        fog(c, c.hy, c.h * 0.04, 0.4)
    elif motif == "city":
        sky_scene(c, 0, 0.7)
        stars(c, int(c.w * c.h / 7000), c.hy * 0.5)
        sun(c, 28 * c.u, 0.7)
        draw_city(c, 3, True, True, True)
        draw_rain(c, int(500 * c.u * (c.h / 1500 if mode == "poster" else 1)), 0.16)
        fog(c, c.hy, c.h * 0.06, 0.25)
    else:
        sky_scene(c, 0, 0.8)
        sun(c, 30 * c.u, 1.0)
        ridges(c, 4, c.hy - c.h * 0.1, c.h * 0.9, c.h * 0.15, c.h * 0.1)
    return finish(c)


def finish(c):
    img, h, w = c.img, c.h, c.w
    P = c.pal
    br = np.clip(img - 0.7, 0, None)
    small = Image.fromarray((np.clip(br * 3, 0, 1) * 255).astype(np.uint8), "RGB").resize((max(8, w // 8), max(8, h // 8)), Image.BILINEAR)
    bl = np.asarray(small.filter(ImageFilter.GaussianBlur(5)).resize((w, h), Image.BICUBIC), np.float32) / 255 / 3
    img = img + bl * 1.3
    wide = Image.fromarray((np.clip(br * 3, 0, 1) * 255).astype(np.uint8), "RGB").resize((max(8, w // 24), max(8, h // 24)), Image.BILINEAR)
    wb = np.asarray(wide.filter(ImageFilter.GaussianBlur(4)).resize((w, h), Image.BICUBIC), np.float32) / 255 / 3
    img = img + wb * 0.9
    over = np.clip(img - 0.82, 0, None)
    img = np.where(img > 0.82, 0.82 + 0.18 * np.tanh(over / 0.18), img)
    lum = img.mean(-1, keepdims=True)
    sh = np.clip(1 - lum * 2.2, 0, 1)
    img = img + sh * (P["sky"][1] * 0.12 + P["dark"] * 0.02)[None, None, :]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = ((xx / w - 0.5) / 0.5) ** 2 + ((yy / h - 0.5) / 0.5) ** 2
    img *= (1 - 0.55 * smooth(0.35, 1.7, d))[..., None]
    if c.mode == "backdrop":
        dist = np.sqrt((xx / w) ** 2 + (((h - yy) / h) * 1.15) ** 2)
        s = (1 - smooth(0.12, 0.95, dist)) * 0.9
        grad = smooth(0.62, 1.0, yy / h) * 0.55
        sd = np.clip(s + grad, 0, 0.95)
        img = img * (1 - sd[..., None]) + (P["dark"] * 0.8)[None, None, :] * sd[..., None]
    elif c.mode == "poster":
        s = smooth(0.58, 0.97, yy / h) * 0.93
        img = img * (1 - s[..., None]) + (P["dark"] * 0.9)[None, None, :] * s[..., None]
        top = (1 - smooth(0.0, 0.12, yy / h)) * 0.35
        img *= (1 - top)[..., None]
    else:
        s = smooth(0.7, 1.0, yy / h) * 0.55
        img = img * (1 - s[..., None]) + (P["dark"] * 0.8)[None, None, :] * s[..., None]
    rng = np.random.default_rng(seed_of("grain", c.motif, c.w, c.h))
    g = rng.normal(0, 0.016, (h, w, 1)).astype(np.float32)
    img = img + g * (0.35 + 0.9 * np.clip(img.mean(-1, keepdims=True) * 1.5, 0, 1))
    out = (np.clip(img, 0, 1) ** (1 / 1.04) * 255).astype(np.uint8)
    return Image.fromarray(out, "RGB")


def tracked_width(f, text, tracking):
    return sum(f.getlength(ch) for ch in text) + tracking * (len(text) - 1)


def draw_tracked(draw, cx, baseline, text, f, tracking, fill):
    wtot = tracked_width(f, text, tracking)
    x = cx - wtot / 2
    for ch in text:
        draw.text((x, baseline), ch, font=f, fill=fill, anchor="ls")
        x += f.getlength(ch) + tracking


def split_title(text, kind, maxw, size_cap, w):
    words = text.split()
    tr_em = FONT_FILES[kind][1]

    def fit(line):
        s = size_cap
        while s > 20:
            f = font(kind, s)
            if tracked_width(f, line, s * tr_em) <= maxw:
                return s
            s -= 4
        return 20
    best = (fit(text), [text])
    if len(words) > 1:
        for i in range(1, len(words)):
            a, b = " ".join(words[:i]), " ".join(words[i:])
            s = min(fit(a), fit(b))
            s = s * 0.92
            if s > best[0] * 1.15 or (len(text) > 16 and s > best[0]):
                best = (int(s), [a, b])
    return best


def compose_text_layer(size, items, glow_col, blur_r):
    w, h = size
    base = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow = Image.new("L", (w, h), 0)
    glowm = Image.new("L", (w, h), 0)
    crisp = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for (cx, baseline, text, f, tracking, fill) in items:
        draw_tracked(ImageDraw.Draw(shadow), cx, baseline + blur_r * 0.5, text, f, tracking, 255)
        draw_tracked(ImageDraw.Draw(glowm), cx, baseline, text, f, tracking, 255)
        draw_tracked(ImageDraw.Draw(crisp), cx, baseline, text, f, tracking, fill)
    sh = shadow.filter(ImageFilter.GaussianBlur(blur_r * 1.2)).point(lambda v: int(v * 0.75))
    base.paste((0, 0, 0, 255), (0, 0), sh)
    gl = glowm.filter(ImageFilter.GaussianBlur(blur_r * 1.6)).point(lambda v: int(v * 0.45))
    base.paste((int(glow_col[0] * 255), int(glow_col[1] * 255), int(glow_col[2] * 255), 255), (0, 0), gl)
    return Image.alpha_composite(base, crisp)


def poster_typography(img, t):
    w, h = img.size
    P = PALETTES[t["style"][0]]
    kind = t["style"][2]
    glow_col = P["accent"]
    items = []
    maxw = w * 0.82
    cap = int(w * 0.18)
    size, lines = split_title(t["title"].upper(), kind, maxw, cap, w)
    tr = size * FONT_FILES[kind][1]
    f = font(kind, size)
    line_h = size * 1.12
    bottom = h * 0.842
    fillc = tuple(int(v * 255) for v in np.clip(0.93 * np.ones(3) * 0.9 + P["glow"] * 0.1, 0, 1)) + (255,)
    for i, line in enumerate(reversed(lines)):
        items.append((w / 2, bottom - i * line_h, line, f, tr, fillc))
    top_y = bottom - (len(lines) - 1) * line_h - size * 0.72
    if t.get("kicker"):
        fk = font("bill", w * 0.026)
        items.append((w / 2, top_y - w * 0.035, t["kicker"], fk, w * 0.026 * 0.34, (255, 255, 255, 190)))
    if t.get("tagline"):
        ft = font("tag", w * 0.032)
        items.append((w / 2, bottom + w * 0.075, t["tagline"], ft, w * 0.032 * 0.04, (240, 235, 225, 215)))
    fb = font("bill", w * 0.0205)
    for j, line in enumerate(t.get("billing", [])):
        s = w * 0.0205
        ff = fb
        while tracked_width(ff, line, s * 0.14) > w * 0.9 and s > 8:
            s -= 1
            ff = font("bill", s)
        items.append((w / 2, h * 0.935 + j * w * 0.034, line, ff, s * 0.14, (225, 225, 225, 165)))
    layer = compose_text_layer((w, h), items, glow_col, w * 0.012)
    out = img.convert("RGBA")
    out = Image.alpha_composite(out, layer)
    d = ImageDraw.Draw(out)
    ly = bottom + w * 0.028
    lw = w * 0.09
    d.line([(w / 2 - lw / 2, ly), (w / 2 + lw / 2, ly)], fill=tuple(int(v * 255) for v in P["accent"]) + (230,), width=max(2, int(w * 0.003)))
    return out.convert("RGB")


def season_typography(img, t):
    w, h = img.size
    P = PALETTES[t["style"][0]]
    kind = t["style"][2]
    items = []
    size, lines = split_title(t["title"].upper(), kind, w * 0.78, int(w * 0.095), w)
    f = font(kind, size)
    tr = size * FONT_FILES[kind][1]
    items.append((w / 2, h * 0.70, lines[0] if len(lines) == 1 else lines[0], f, tr, (235, 235, 230, 235)))
    if len(lines) > 1:
        items.append((w / 2, h * 0.70 + size * 1.1, lines[1], f, tr, (235, 235, 230, 235)))
    label = f"SEASON {t['season']}"
    s2, l2 = split_title(label, "cond", w * 0.8, int(w * 0.16), w)
    f2 = font("cond", s2)
    yb = h * 0.84 + (size * 1.1 if len(lines) > 1 else 0) * 0.3
    items.append((w / 2, yb, label, f2, s2 * 0.16, (255, 255, 255, 255)))
    layer = compose_text_layer((w, h), items, P["accent"], w * 0.012)
    out = Image.alpha_composite(img.convert("RGBA"), layer)
    return out.convert("RGB")


def avatar(name, size=400):
    rng = np.random.default_rng(seed_of("avatar", name))
    keys = list(PALETTES)
    p = PALETTES[keys[int(rng.integers(len(keys)))]]
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    t = np.clip((xx * 0.5 + yy * 0.9) / (size * 1.4), 0, 1)
    c1, c2 = p["sky"][2] * 0.9, p["sky"][1] * 0.8
    img = c1[None, None, :] * (1 - t[..., None]) + c2[None, None, :] * t[..., None]
    gl = np.exp((-(((xx - size * 0.3) ** 2 + (yy - size * 0.25) ** 2) / (size * 0.5) ** 2)) * 1.3)
    img = img + p["glow"][None, None, :] * gl[..., None] * 0.35
    g = rng.normal(0, 0.018, (size, size, 1)).astype(np.float32)
    im = Image.fromarray((np.clip(img + g, 0, 1) * 255).astype(np.uint8), "RGB").convert("RGBA")
    d = ImageDraw.Draw(im)
    parts = name.split()
    initials = "".join(x[0] for x in parts[:2]).upper()
    f = font("bold", size * 0.36)
    d.text((size / 2, size / 2), initials, font=f, fill=(255, 255, 255, 235), anchor="mm")
    return im.convert("RGB")


def job(task):
    try:
        return render_job(task)
    except Exception as exc:
        import traceback
        traceback.print_exc()
        return f"FAILED {task['file']}: {exc!r}"


def render_job(task):
    kind = task["kind"]
    path = os.path.join(OUT, task["file"])
    if kind == "poster":
        img = render_scene(1000, 1500, task["style"], "poster", task.get("variant", 0))
        img = (season_typography if task.get("season") else poster_typography)(img, task)
    elif kind == "backdrop":
        img = render_scene(1920, 1080, task["style"], "backdrop")
    elif kind == "still":
        img = render_scene(1280, 720, task["style"], "still", task["variant"])
    else:
        img = avatar(task["name"])
    img.save(path, "JPEG", quality=90 if kind != "still" else 86, optimize=True, subsampling=0 if kind == "poster" else 2)
    return task["file"]


def billing_for(it):
    names = [n.upper() for n, _ in it["_cast"][:4]]
    line1 = "  •  ".join(names)
    if it["type"] == "movie":
        d = it["_directors"][0].upper() if it["_directors"] else ""
        line2 = f"A {it['studio'].upper()} PRODUCTION  •  DIRECTED BY {d}"
    else:
        line2 = f"A {it['studio'].upper()} ORIGINAL SERIES  •  CREATED BY {it['_writers'][0].upper()}"
    return [line1, line2]


def build_tasks(lib, only=None):
    tasks = []
    for it in list(lib.movies) + list(lib.shows):
        rk = it["ratingKey"]
        kicker = "ORIGINAL SERIES" if it["type"] == "show" else None
        tasks.append(dict(kind="poster", file=f"poster_{rk}.jpg", style=it["_style"], title=it["title"],
                          tagline=it.get("tagline", ""), billing=billing_for(it), kicker=kicker))
        tasks.append(dict(kind="backdrop", file=f"backdrop_{rk}.jpg", style=it["_style"]))
    for show in lib.shows:
        for season in show["_seasons"]:
            tasks.append(dict(kind="poster", file=f"poster_{season['ratingKey']}.jpg", style=show["_style"],
                              title=show["title"], season=season["_season"], variant=season["_season"]))
            for ep in season["_episodes"]:
                tasks.append(dict(kind="still", file=f"still_{ep['ratingKey']}.jpg", style=show["_style"],
                                  variant=int(ep["ratingKey"])))
    for slug_, name in sorted(lib.actors.items()):
        tasks.append(dict(kind="avatar", file=f"actor_{slug_}.jpg", name=name))
    if only:
        tasks = [t for t in tasks if any(o in t["file"] for o in only)]
    return tasks


def contact_sheet(lib):
    posters = [os.path.join(OUT, f"poster_{i['ratingKey']}.jpg") for i in list(lib.movies) + list(lib.shows)]
    posters = [p for p in posters if os.path.exists(p)]
    tw, th, cols = 220, 330, 11
    rows = (len(posters) + cols - 1) // cols
    backs = [os.path.join(OUT, f"backdrop_{i['ratingKey']}.jpg") for i in list(lib.movies)[:8] + list(lib.shows)[:4]]
    backs = [b for b in backs if os.path.exists(b)]
    bw, bh, bcols = 480, 270, 5
    brows = (len(backs) + bcols - 1) // bcols
    W = max(cols * tw, bcols * bw)
    sheet = Image.new("RGB", (W, rows * th + brows * bh), (10, 10, 12))
    for i, p in enumerate(posters):
        sheet.paste(Image.open(p).resize((tw, th), Image.LANCZOS), ((i % cols) * tw, (i // cols) * th))
    for i, p in enumerate(backs):
        sheet.paste(Image.open(p).resize((bw, bh), Image.LANCZOS), ((i % bcols) * bw, rows * th + (i // bcols) * bh))
    sheet.save(os.path.join(OUT, "_contact.jpg"), quality=88)


def main():
    only = sys.argv[1:]
    os.makedirs(OUT, exist_ok=True)
    lib = library.Library()
    tasks = build_tasks(lib, only)
    t0 = time.time()
    with Pool() as pool:
        for i, name in enumerate(pool.imap_unordered(job, tasks, chunksize=1), 1):
            if i % 25 == 0 or i == len(tasks):
                print(f"{i}/{len(tasks)} {name}", flush=True)
    contact_sheet(lib)
    print(f"done in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
