#!/usr/bin/env python3
"""Generates tv/Resources/Assets.xcassets: layered tvOS app icon, Top Shelf images and colour sets.

The crystal geometry and palette mirror CrystalGlyphView in Sources/Crucible/App/LaunchViewController.swift.
Run from anywhere: python3 tv/scripts/make-assets.py [--preview]
--preview also writes composites and a parallax contact sheet to tv/out/assets-preview/.
"""
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
TV = os.path.dirname(HERE)
CATALOG = os.path.join(TV, "Resources", "Assets.xcassets")
BRAND = os.path.join(CATALOG, "App Icon & Top Shelf Image.brandassets")
PREVIEW = os.path.join(TV, "out", "assets-preview")
FONT = "/usr/share/fonts/TTF/Roboto-Medium.ttf"

INFO = {"author": "xcode", "version": 1}
SS = 4

OUTLINE = [(0.5, 0.14), (0.707, 0.41), (0.707, 0.59), (0.5, 0.86), (0.293, 0.59), (0.293, 0.41)]
FACETS = [(0, 3), (5, 2), (1, 4)]
BODY_STOPS = [(0.0, (1.0, 0.62, 0.25)), (0.5, (0.93, 0.45, 0.10)), (1.0, (0.55, 0.24, 0.06))]
EDGE = (1.0, 0.78, 0.48)
FACET = (1.0, 0.85, 0.62)
EMBER = (1.0, 0.45, 0.05)
CORE_STOPS = [
    (0.0, (1.0, 1.0, 1.0, 1.0)),
    (0.12, (1.0, 0.78, 0.35, 1.0)),
    (0.45, (1.0, 0.45, 0.02, 0.85)),
    (1.0, (1.0, 0.40, 0.0, 0.0)),
]


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def piecewise(t, stops):
    """Interpolates the stop list [(position, value-tuple)] at every element of t."""
    positions = [p for p, _ in stops]
    channels = len(stops[0][1])
    return np.stack([np.interp(t, positions, [v[c] for _, v in stops]) for c in range(channels)], axis=-1)


def to_image(rgba):
    return Image.fromarray((np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def grid(w, h):
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return xs + 0.5, ys + 0.5


def radial_t(w, h, cx, cy, rx, ry):
    xs, ys = grid(w, h)
    return np.sqrt(((xs - cx) / rx) ** 2 + ((ys - cy) / ry) ** 2)


def crystal_points(cx, cy, side):
    ox, oy = cx - side / 2, cy - side / 2
    return [(ox + x * side, oy + y * side) for x, y in OUTLINE]


def shape_mask(w, h, draw_fn):
    """Draws with draw_fn(ImageDraw, scale) on a supersampled L canvas and returns the antialiased mask as float [0,1]."""
    big = Image.new("L", (w * SS, h * SS), 0)
    draw_fn(ImageDraw.Draw(big), SS)
    return np.asarray(big.resize((w, h), Image.LANCZOS), dtype=np.float32) / 255.0


def stroke_polygon(d, pts, width, scale, fill=255):
    scaled = [(x * scale, y * scale) for x, y in pts]
    d.line(scaled + [scaled[0]], fill=fill, width=int(round(width * scale)), joint="curve")
    r = width * scale / 2
    for x, y in scaled:
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def stroke_segments(d, pts, segments, width, scale):
    r = width * scale / 2
    for a, b in segments:
        p, q = pts[a], pts[b]
        d.line([(p[0] * scale, p[1] * scale), (q[0] * scale, q[1] * scale)], fill=255, width=int(round(width * scale)))
        for x, y in (p, q):
            d.ellipse([x * scale - r, y * scale - r, x * scale + r, y * scale + r], fill=255)


def solid(w, h, rgb, mask):
    out = np.zeros((h, w, 4), dtype=np.float32)
    out[..., 0], out[..., 1], out[..., 2] = rgb
    out[..., 3] = mask
    return out


def over(base, top):
    """Straight-alpha source-over of two float RGBA arrays."""
    ta, ba = top[..., 3:4], base[..., 3:4]
    out_a = ta + ba * (1 - ta)
    safe = np.where(out_a > 0, out_a, 1)
    rgb = (top[..., :3] * ta + base[..., :3] * ba * (1 - ta)) / safe
    return np.concatenate([rgb, out_a], axis=-1)


def crystal_layer(w, h, cx, cy, side):
    """The faceted crystal alone on transparency: gradient body, facet lines, luminous edge and hot core."""
    pts = crystal_points(cx, cy, side)
    body_mask = shape_mask(w, h, lambda d, s: d.polygon([(x * s, y * s) for x, y in pts], fill=255))
    xs, ys = grid(w, h)
    ox, oy = cx - side / 2, cy - side / 2
    u, v = (xs - ox) / side, (ys - oy) / side
    sx, sy, ex, ey = 0.15, 0.1, 0.85, 0.95
    dx, dy = ex - sx, ey - sy
    t = np.clip(((u - sx) * dx + (v - sy) * dy) / (dx * dx + dy * dy), 0, 1)
    body = np.concatenate([piecewise(t, BODY_STOPS), body_mask[..., None]], axis=-1).astype(np.float32)

    facet_mask = shape_mask(w, h, lambda d, s: stroke_segments(d, pts, FACETS, side * 0.0075, s))
    facets = solid(w, h, FACET, facet_mask * 0.55)

    edge_mask = shape_mask(w, h, lambda d, s: stroke_polygon(d, pts, side * 0.0185, s))
    edges = solid(w, h, EDGE, edge_mask)

    core_r = side * 0.34 / 2
    ct = radial_t(w, h, cx, cy, core_r, core_r)
    core = piecewise(np.clip(ct, 0, 1), CORE_STOPS).astype(np.float32)
    core[..., 3] *= (ct <= 1.0) * np.clip((1.0 - ct) * core_r, 0, 1)

    layer = over(over(over(body, facets), edges), core)
    return layer


def glow_layer(w, h, cx, cy, side, rx, ry):
    """Soft ember halo plus a blurred edge halo; no hard shapes so parallax never reveals a seam."""
    t = radial_t(w, h, cx, cy, rx, ry)
    falloff = (1 - smoothstep(t)) ** 1.6
    alpha = 0.62 * falloff
    pts = crystal_points(cx, cy, side)
    outline = shape_mask(w, h, lambda d, s: stroke_polygon(d, pts, side * 0.03, s))
    blur = Image.fromarray((outline * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(side * 0.035))
    halo = np.asarray(blur, dtype=np.float32) / 255.0 * 0.9
    ambient = solid(w, h, EMBER, alpha)
    ring = solid(w, h, (1.0, 0.6, 0.2), np.clip(halo, 0, 1))
    return over(ambient, ring)


def background_layer(w, h, cx, cy, rx, ry):
    """Opaque warm-to-black vignette: the canvas colour at the rim, a faint ember warmth behind the crystal."""
    t = radial_t(w, h, cx, cy, rx, ry)
    mix = (1 - smoothstep(t))[..., None]
    edge = np.array([0.060, 0.056, 0.056], dtype=np.float32)
    centre = np.array([0.150, 0.098, 0.062], dtype=np.float32)
    rgb = edge + (centre - edge) * mix
    return np.concatenate([rgb, np.ones((h, w, 1), dtype=np.float32)], axis=-1)


def icon_layers(w, h):
    cx, cy = w / 2, h / 2
    side = h * 0.70 / 0.72
    back = background_layer(w, h, cx, cy, w * 0.62, h * 0.95)
    glow = glow_layer(w, h, cx, cy, side, w * 0.38, h * 0.47)
    front = crystal_layer(w, h, cx, cy, side)
    return {"Back": to_image(back), "Middle": to_image(glow), "Front": to_image(front)}


def wordmark(w, h, text, x, y_center, size):
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    font = ImageFont.truetype(FONT, int(size * SS))
    tracking = size * 0.045 * SS
    cursor = x * SS
    box_top = None
    for ch in text:
        left, top, right, bottom = d.textbbox((cursor, 0), ch, font=font)
        box_top = top if box_top is None else min(box_top, top)
        d.text((cursor, 0), ch, font=font, fill=255)
        cursor += d.textlength(ch, font=font) + tracking
    mask = np.asarray(big.resize((w, h), Image.LANCZOS), dtype=np.float32) / 255.0
    height = size * 0.74
    shift = int(round(y_center - height / 2 - box_top / SS))
    return np.roll(mask, shift, axis=0)


def top_shelf(w, h, scale):
    """Static Top Shelf fallback: crystal and wordmark kept inside the central 1920pt so the wide variant crops cleanly."""
    W, H = w * scale, h * scale
    span = 1920 * scale
    left = (W - span) / 2
    cy = H * 0.5
    side = H * 0.80 / 0.72
    cx = left + span * 0.74
    back = background_layer(W, H, cx, cy, span * 0.75, H * 1.35)
    glow = glow_layer(W, H, cx, cy, side, span * 0.34, H * 0.62)
    crystal = crystal_layer(W, H, cx, cy, side)
    out = over(over(back, glow), crystal)
    text_x = left + span * 0.09
    word = wordmark(W, H, "Crucible", text_x, cy - H * 0.06, 118 * scale)
    out = over(out, solid(W, H, (1.0, 0.96, 0.9), word * 0.96))
    tag = wordmark(W, H, "Plex, on the big screen", text_x + 6 * scale, cy + H * 0.15, 40 * scale)
    out = over(out, solid(W, H, (1.0, 0.72, 0.38), tag * 0.9))
    return to_image(out).convert("RGB")


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")


def write_imagestack(name, w, h, scales):
    stack = os.path.join(BRAND, name)
    write_json(
        os.path.join(stack, "Contents.json"),
        {"info": INFO, "layers": [{"filename": f"{layer}.imagestacklayer"} for layer in ("Front", "Middle", "Back")]},
    )
    renders = {s: icon_layers(w * s, h * s) for s in scales}
    for layer in ("Front", "Middle", "Back"):
        layer_dir = os.path.join(stack, f"{layer}.imagestacklayer")
        write_json(os.path.join(layer_dir, "Contents.json"), {"info": INFO})
        images = []
        for s in scales:
            filename = f"{layer.lower()}@{s}x.png"
            path = os.path.join(layer_dir, "Content.imageset", filename)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            renders[s][layer].save(path, optimize=True)
            images.append({"filename": filename, "idiom": "tv", "scale": f"{s}x"})
        write_json(os.path.join(layer_dir, "Content.imageset", "Contents.json"), {"images": images, "info": INFO})
    return renders


def write_top_shelf(name, w, h):
    imageset = os.path.join(BRAND, name)
    os.makedirs(imageset, exist_ok=True)
    images = []
    previews = {}
    for s in (1, 2):
        filename = f"top-shelf-{w}x{h}@{s}x.png"
        image = top_shelf(w, h, s)
        image.save(os.path.join(imageset, filename), optimize=True)
        images.append({"filename": filename, "idiom": "tv", "scale": f"{s}x"})
        previews[s] = image
    write_json(os.path.join(imageset, "Contents.json"), {"images": images, "info": INFO})
    return previews


def write_color_set(name, rgb):
    components = {"alpha": "1.000", "red": f"{rgb[0]:.3f}", "green": f"{rgb[1]:.3f}", "blue": f"{rgb[2]:.3f}"}
    write_json(
        os.path.join(CATALOG, f"{name}.colorset", "Contents.json"),
        {"colors": [{"color": {"color-space": "srgb", "components": components}, "idiom": "universal"}], "info": INFO},
    )


def rounded_preview(image, radius_fraction=0.06):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, image.width - 1, image.height - 1], radius=int(image.height * radius_fraction), fill=255)
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(image.convert("RGBA"), (0, 0), mask)
    return out


def parallax_composite(layers, dx):
    """Front/middle/back stacked with the layers shifted apart by dx pixels, as the focus parallax would."""
    w, h = layers["Back"].size
    canvas = layers["Back"].convert("RGBA")
    for layer, shift in (("Middle", dx // 2), ("Front", dx)):
        shifted = ImageChops.offset(layers[layer], shift, 0)
        canvas = Image.alpha_composite(canvas, shifted)
    return canvas


def write_previews(large, small, shelf, wide):
    os.makedirs(PREVIEW, exist_ok=True)
    sheet = Image.new("RGB", (2640, 1500), (34, 34, 36))
    flat = parallax_composite(large[1], 0)
    shifted = parallax_composite(large[1], 36)
    sheet.paste(rounded_preview(flat), (40, 40), rounded_preview(flat))
    sheet.paste(rounded_preview(shifted), (1340, 40), rounded_preview(shifted))
    small_flat = parallax_composite(small[2], 0)
    sheet.paste(rounded_preview(small_flat), (40, 860), rounded_preview(small_flat))
    small_1x = parallax_composite(small[1], 0)
    sheet.paste(rounded_preview(small_1x), (860, 860), rounded_preview(small_1x))
    for name, layers in (("front", large[1]["Front"]), ("middle", large[1]["Middle"]), ("back", large[1]["Back"])):
        checker = Image.new("RGBA", layers.size, (60, 60, 64, 255))
        px = ImageDraw.Draw(checker)
        for gy in range(0, layers.height, 32):
            for gx in range(0, layers.width, 32):
                if (gx // 32 + gy // 32) % 2:
                    px.rectangle([gx, gy, gx + 31, gy + 31], fill=(90, 90, 96, 255))
        checker.alpha_composite(layers)
        checker.convert("RGB").save(os.path.join(PREVIEW, f"layer-{name}.png"))
    parallax_composite(large[1], 0).convert("RGB").save(os.path.join(PREVIEW, "icon-large.png"))
    sheet.save(os.path.join(PREVIEW, "contact-sheet.png"))
    shelf[1].save(os.path.join(PREVIEW, "top-shelf.png"))
    wide[1].save(os.path.join(PREVIEW, "top-shelf-wide.png"))


def main():
    shutil.rmtree(CATALOG, ignore_errors=True)
    write_json(os.path.join(CATALOG, "Contents.json"), {"info": INFO})
    write_json(
        os.path.join(BRAND, "Contents.json"),
        {
            "assets": [
                {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
                {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
                {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
                {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
            ],
            "info": INFO,
        },
    )
    large = write_imagestack("App Icon - Large.imagestack", 1280, 768, (1,))
    small = write_imagestack("App Icon - Small.imagestack", 400, 240, (1, 2))
    shelf = write_top_shelf("Top Shelf Image.imageset", 1920, 720)
    wide = write_top_shelf("Top Shelf Image Wide.imageset", 2320, 720)
    write_color_set("AccentColor", (1.0, 0x9F / 255, 0x0A / 255))
    write_color_set("LaunchBackground", (0x18 / 255, 0x18 / 255, 0x18 / 255))
    if "--preview" in sys.argv:
        write_previews(large, small, shelf, wide)


if __name__ == "__main__":
    main()
