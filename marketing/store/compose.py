#!/usr/bin/python3
"""Compose Crucible's App Store screenshots from raw simulator captures.

Usage: marketing/store/compose.py [iphone|ipad ...]   (defaults to both)

iphone: 1320x2868 captures from marketing/shots/out/raw-dark (marketing/shots/run.sh on an iPhone 17 Pro Max in US English) become
the 6.9-inch set in marketing/appstore/iphone. ipad: 2752x2064 landscape captures from marketing/shots/out/raw-ipad
(marketing/store/shoot-ipad.sh) become the 13-inch set in marketing/appstore/ipad. Every device is shown whole, scaled to the room
under the captions. Each entry of captions.json names a
capture, a headline and a subhead; the capture is set into Apple's bezel by the `frames` CLI, placed on the ember gradient
with a soft shadow, and the captions are typeset above it. scripts/asc-screenshots.py uploads both folders.
"""

import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FRAMES = os.path.realpath(os.path.expanduser("~/.local/bin/frames"))
SANS = "/System/Library/Fonts/SFNS.ttf"

GRADIENT_TOP = (46, 26, 10)
GRADIENT_BOTTOM = (9, 8, 7)
GLOW = (255, 138, 28)
HEADLINE_COLOR = (255, 255, 255)
SUBHEAD_COLOR = (242, 199, 142)

DEVICES = {
    "iphone": {
        "raw": os.path.join(ROOT, "marketing/shots/out/raw-dark"),
        "out": os.path.join(ROOT, "marketing/appstore/iphone"),
        "size": (1320, 2868),
        "color": "Black",
        "device_width": 1150,
        "headline_top": 150,
        "headline": (112, 84, 132),
        "subhead": (54, 42, 68),
        "gap": 60,
        "device_gap": 80,
        "text_margin": 80,
        "bleed": False,
    },
    "ipad": {
        "raw": os.path.join(ROOT, "marketing/shots/out/raw-ipad"),
        "out": os.path.join(ROOT, "marketing/appstore/ipad"),
        "size": (2752, 2064),
        "color": None,
        "device_width": 2440,
        "headline_top": 104,
        "headline": (108, 84, 124),
        "subhead": (54, 44, 66),
        "gap": 36,
        "device_gap": 64,
        "text_margin": 200,
        "bleed": False,
    },
}


def font(weight, size):
    face = ImageFont.truetype(SANS, size)
    face.set_variation_by_name(weight)
    return face


def wrap(text, face, width):
    lines, current = [], ""
    for word in text.split():
        trial = f"{current} {word}".strip()
        if face.getlength(trial) <= width or not current:
            current = trial
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return balance(lines, face, width)


def balance(lines, face, width):
    """Two ragged lines read better when their lengths are close; a one-word last line reads as a typo."""
    if len(lines) != 2:
        return lines
    words = " ".join(lines).split()
    best = lines
    for split in range(1, len(words)):
        first, second = " ".join(words[:split]), " ".join(words[split:])
        if face.getlength(first) > width or face.getlength(second) > width:
            continue
        if abs(face.getlength(first) - face.getlength(second)) < abs(face.getlength(best[0]) - face.getlength(best[1])):
            best = [first, second]
    return best


def fit(text, weight, spec, width, max_lines):
    """The largest size from `spec` (size, minimum, leading) at which `text` fits in `max_lines` lines."""
    size, minimum, leading = spec
    current = size
    while True:
        face = font(weight, current)
        lines = wrap(text, face, width)
        if (len(lines) <= max_lines and all(face.getlength(line) <= width for line in lines)) or current <= minimum:
            return face, lines, round(leading * current / size)
        current -= 2


def background(size):
    width, height = size
    t = np.linspace(0, 1, height)[:, None, None]
    top, bottom = np.array(GRADIENT_TOP, np.float32), np.array(GRADIENT_BOTTOM, np.float32)
    canvas = np.repeat(top * (1 - t) + bottom * t, width, axis=1)
    yy, xx = np.mgrid[0:height, 0:width]
    glow = np.exp(-(((xx - width / 2) / (width * 0.45)) ** 2 + ((yy - height * 0.04) / (height * 0.2)) ** 2))
    canvas += glow[..., None] * (np.array(GLOW, np.float32) - top) * 0.42
    return Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8)).convert("RGBA")


def framed(path, color, width):
    """The capture inside Apple's own bezel for its device, rendered by the frames CLI and trimmed to the device."""
    out_dir = tempfile.mkdtemp(prefix="frames-")
    command = ["/usr/bin/python3", FRAMES, "--json", "-o", out_dir, path]
    if color:
        command[3:3] = ["-c", color]
    run = subprocess.run(command, check=True, capture_output=True, text=True)
    device = Image.open(json.loads(run.stdout)["output"]).convert("RGBA")
    device = device.crop(device.getchannel("A").getbbox())
    return device.resize((width, round(device.height * width / device.width)), Image.LANCZOS)


def paste_with_shadow(canvas, device, xy):
    x, y = xy
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 170), (x, y + round(device.width * 0.016)), device.getchannel("A"))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(round(device.width * 0.03))))
    canvas.alpha_composite(device, (x, y))


def draw_lines(draw, lines, face, leading, top, width, color):
    cap = face.getbbox("H")[1]
    for index, line in enumerate(lines):
        draw.text(((width - face.getlength(line)) / 2, top + index * leading - cap), line, font=face, fill=color)
    return top + leading * len(lines)


def typeset(kind, entry):
    spec = DEVICES[kind]
    text_width = spec["size"][0] - 2 * spec["text_margin"]
    return fit(entry["headline"], "Bold", spec["headline"], text_width, 2), fit(entry["subhead"], "Medium", spec["subhead"], text_width, 2)


def caption_bottom(kind, entry):
    spec = DEVICES[kind]
    headline, subhead = typeset(kind, entry)
    return spec["headline_top"] + headline[2] * len(headline[1]) + spec["gap"] + subhead[2] * len(subhead[1])


def compose(kind, entry, device_top):
    """One screenshot: the captions centred in the band above `device_top`, where every device of the set starts."""
    spec = DEVICES[kind]
    width, height = spec["size"]
    path = os.path.join(spec["raw"], f"{entry['screen']}.png")
    with Image.open(path) as capture:
        if capture.size != spec["size"]:
            sys.exit(f"{kind}/{entry['screen']}: capture is {capture.size}, expected {spec['size']}")
    canvas = background(spec["size"])
    draw = ImageDraw.Draw(canvas)
    headline, subhead = typeset(kind, entry)
    offset = (device_top - spec["device_gap"] - caption_bottom(kind, entry)) // 2
    y = draw_lines(draw, headline[1], headline[0], headline[2], spec["headline_top"] + offset, width, HEADLINE_COLOR)
    draw_lines(draw, subhead[1], subhead[0], subhead[2], y + spec["gap"], width, SUBHEAD_COLOR)
    device = framed(path, spec["color"], spec["device_width"])
    top = device_top
    if not spec["bleed"] and top + device.height > height - spec["device_gap"]:
        scale = (height - spec["device_gap"] - top) / device.height
        device = device.resize((round(device.width * scale), round(device.height * scale)), Image.LANCZOS)
    paste_with_shadow(canvas, device, ((width - device.width) // 2, top))
    return canvas.convert("RGB")


def main():
    kinds = sys.argv[1:] or list(DEVICES)
    captions = json.load(open(os.path.join(HERE, "captions.json")))
    for kind in kinds:
        out = DEVICES[kind]["out"]
        os.makedirs(out, exist_ok=True)
        for name in os.listdir(out):
            if name.endswith(".png"):
                os.remove(os.path.join(out, name))
        device_top = max(caption_bottom(kind, entry) for entry in captions[kind]) + DEVICES[kind]["device_gap"]
        for index, entry in enumerate(captions[kind], start=1):
            target = os.path.join(out, f"{index:02d}-{entry['screen']}.png")
            compose(kind, entry, device_top).save(target, optimize=True)
            print(target, flush=True)


if __name__ == "__main__":
    main()
