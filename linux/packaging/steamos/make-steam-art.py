#!/usr/bin/env python3
"""Draws Crucible's Steam library artwork from the Apple TV app icon's layers and the bundled Inter Display, into
linux/packaging/steamos/steam-art: the portrait capsule (600x900), the wide capsule (920x430), the hero (3840x1240) and the
logo Steam lays over the hero. Needs Pillow.

    linux/packaging/steamos/make-steam-art.py
"""
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", "..", ".."))
STACK = os.path.join(REPO, "tv", "Resources", "Assets.xcassets", "App Icon & Top Shelf Image.brandassets", "App Icon - Large.imagestack")
FONT = os.path.join(REPO, "linux", "Sources", "Kiln", "Resources", "Fonts", "KilnInterDisplay-Bold.ttf")
TEXT_FONT = os.path.join(REPO, "linux", "Sources", "Kiln", "Resources", "Fonts", "KilnInter-Medium.ttf")
OUT = os.path.join(ROOT, "steam-art")

INK = (244, 236, 226)
AMBER = (240, 168, 82)
BASE = (17, 14, 13)
GLOW = (255, 120, 24)


def layer(name):
    return Image.open(os.path.join(STACK, f"{name}.imagestacklayer", "Content.imageset", f"{name.lower()}@1x.png")).convert("RGBA")


def crystal():
    """The icon's crystal and its glow, cropped to what is drawn."""
    front = layer("Front")
    middle = layer("Middle")
    merged = Image.alpha_composite(middle, front)
    return merged.crop(merged.getbbox())


def backdrop(width, height, centre, radius):
    """The warm near-black of the Top Shelf image with an ember glow around `centre`, fading into a darker vignette."""
    glow = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(glow)
    steps = 64
    for step in range(steps, 0, -1):
        r = radius * step / steps
        draw.ellipse((centre[0] - r, centre[1] - r, centre[0] + r, centre[1] + r), fill=int(255 * (1 - step / steps) ** 1.6))
    glow = glow.filter(ImageFilter.GaussianBlur(radius / 12))
    image = Image.composite(Image.new("RGB", (width, height), (122, 50, 14)), Image.new("RGB", (width, height), BASE), glow)
    vignette = Image.new("L", (width, height), 0)
    ImageDraw.Draw(vignette).ellipse((-width * 0.3, -height * 0.3, width * 1.3, height * 1.3), fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(min(width, height) / 5))
    return Image.composite(image, Image.new("RGB", (width, height), (7, 6, 5)), vignette)


def place_crystal(canvas, height, centre):
    gem = crystal()
    scale = height / gem.height
    gem = gem.resize((max(1, round(gem.width * scale)), max(1, round(gem.height * scale))), Image.Resampling.LANCZOS)
    canvas.paste(gem, (round(centre[0] - gem.width / 2), round(centre[1] - gem.height / 2)), gem)


def wordmark(size, colour=INK):
    font = ImageFont.truetype(FONT, size)
    box = font.getbbox("Crucible")
    image = Image.new("RGBA", (box[2] - box[0] + size // 4, box[3] - box[1] + size // 4), (0, 0, 0, 0))
    ImageDraw.Draw(image).text((size // 8 - box[0], size // 8 - box[1]), "Crucible", font=font, fill=colour + (255,))
    return image


def tagline(size, text="Plex, beautifully on Steam Deck"):
    font = ImageFont.truetype(TEXT_FONT, size)
    box = font.getbbox(text)
    image = Image.new("RGBA", (box[2] - box[0] + 4, box[3] - box[1] + 4), (0, 0, 0, 0))
    ImageDraw.Draw(image).text((2 - box[0], 2 - box[1]), text, font=font, fill=AMBER + (255,))
    return image


def shadowed(canvas, image, origin, blur):
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow.putalpha(image.getchannel("A").point(lambda a: a * 0.55))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(shadow, (origin[0], origin[1] + blur // 2), shadow)
    canvas.paste(image, origin, image)


def capsule():
    width, height = 600, 900
    canvas = backdrop(width, height, (width / 2, 360), 470).convert("RGBA")
    place_crystal(canvas, 540, (width / 2, 360))
    mark = wordmark(116)
    shadowed(canvas, mark, ((width - mark.width) // 2, 640), 10)
    line = tagline(30)
    canvas.paste(line, ((width - line.width) // 2, 650 + mark.height + 18), line)
    return canvas.convert("RGB")


def wide():
    width, height = 920, 430
    canvas = backdrop(width, height, (705, height / 2), 330).convert("RGBA")
    place_crystal(canvas, 390, (705, height / 2))
    mark = wordmark(108)
    line = tagline(28)
    top = (height - (mark.height + 10 + line.height)) // 2
    shadowed(canvas, mark, (60, top), 9)
    canvas.paste(line, (74, top + mark.height + 10), line)
    return canvas.convert("RGB")


def hero():
    """Steam shows the hero's middle band (about three quarters of its height on a Steam Deck), so the crystal stays inside it."""
    width, height = 3840, 1240
    canvas = backdrop(width, height, (2880, height / 2), 900).convert("RGBA")
    place_crystal(canvas, 720, (2880, height / 2))
    return canvas.convert("RGB")


def logo():
    mark = wordmark(300)
    return mark


def main():
    os.makedirs(OUT, exist_ok=True)
    capsule().save(os.path.join(OUT, "capsule.png"), optimize=True)
    wide().save(os.path.join(OUT, "wide.png"), optimize=True)
    hero().save(os.path.join(OUT, "hero.png"), optimize=True)
    logo().save(os.path.join(OUT, "logo.png"), optimize=True)
    print(f"make-steam-art: {OUT}")


if __name__ == "__main__":
    main()
