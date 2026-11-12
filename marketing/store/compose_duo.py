#!/usr/bin/python3
"""Compose Crucible's iPhone Duo screenshots and its product page Header and Search Results images.

Usage: marketing/store/compose_duo.py [duo] [header] [--locale LOCALE] [--raw DIR]

duo: the ten Duo screenshots, one story each from captions.json's "duo" list, at the size of the display it was
captured on (inner landscape 2853x2007, inner portrait 2007x2853, outer portrait 1398x2034, outer landscape
2034x1398), into marketing/appstore/duo/<locale>. Captures come from DIR/<state>-<language>/<screen>.png, as
marketing/shots/duo-run.sh writes them for each Duo state; every capture is set into Apple's Duo bezel by the
`frames` CLI and placed on the ember gradient under its localized caption, as the iPhone set is.

header: the 5244x2950 universal image App Store Connect takes for both the product page Header and the Search Results
placement, into marketing/appstore/header/<locale>: header.png carries the icon, the name and the app's subtitle over
Home on the inner display and a title on the outer one; search.png shows the app's purpose at a glance, the Essentials offer on the inner display
beside Home on the outer one. Arabic and Thai, which this pipeline cannot shape, use the English text, as their
screenshots do.
"""

import json
import os
import sys

from PIL import Image, ImageDraw

import compose

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STORE_LOCALES = ["en-US", "ar-SA", "de-DE", "es-ES", "fr-FR", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant"]
UNSHAPED = {"ar-SA", "th"}

SIZES = {
    "inner-landscape": {"size": (2853, 2007), "headline": (124, 92, 142), "subhead": (64, 50, 80), "headline_top": 96, "gap": 28, "text_margin": 330, "device_gap": 64, "bottom": 56},
    "inner-portrait": {"size": (2007, 2853), "headline": (146, 108, 168), "subhead": (76, 58, 94), "headline_top": 140, "gap": 36, "text_margin": 140, "device_gap": 84, "bottom": 70},
    "outer-portrait": {"size": (1398, 2034), "headline": (108, 82, 126), "subhead": (56, 44, 70), "headline_top": 104, "gap": 28, "text_margin": 84, "device_gap": 64, "bottom": 60},
    "outer-landscape": {"size": (2034, 1398), "headline": (98, 76, 114), "subhead": (52, 40, 64), "headline_top": 72, "gap": 24, "text_margin": 230, "device_gap": 48, "bottom": 44},
}

HEADER_SIZE = (5244, 2950)


def language_of(locale):
    """The capture language for an App Store locale: its own where the app is localized, English elsewhere."""
    return compose.LANGUAGE.get(locale, "en")


def captions_for(captions, locale):
    """The Duo stories with the locale's headline and subhead where the iPhone set has them translated."""
    text = captions["l10n"].get(locale, {}) if locale != "en-US" else {}
    stories = []
    for entry in captions["duo"]:
        base = next(item for item in captions["iphone"] if item["screen"] == entry["screen"])
        stories.append({**base, **text.get(entry["screen"], {}), **entry})
    return stories


def typeset(spec, entry):
    width = spec["size"][0] - 2 * spec["text_margin"]
    headline = compose.fit(entry["headline"], "Bold", spec["headline"], width, 2)
    subhead = compose.fit(entry["subhead"], "Medium", spec["subhead"], width, 2)
    return headline, subhead


def caption_height(spec, entry):
    headline, subhead = typeset(spec, entry)
    return headline[2] * len(headline[1]) + spec["gap"] + subhead[2] * len(subhead[1])


def panel(entry, raw_dir, device_tops):
    """One Duo screenshot: the caption centred in the band above the device, the device as large as the room allows."""
    spec = SIZES[entry["state"]]
    width, height = spec["size"]
    path = os.path.join(raw_dir, f"{entry.get('from', entry['state'])}-{entry['language']}", f"{entry['screen']}.png")
    with Image.open(path) as capture:
        if capture.size != spec["size"]:
            sys.exit(f"{entry['screen']}: {entry['state']} capture is {capture.size}, expected {spec['size']}")
    canvas = compose.background(spec["size"])
    draw = ImageDraw.Draw(canvas)
    headline, subhead = typeset(spec, entry)
    device_top = device_tops[entry["state"]]
    top = spec["headline_top"] + (device_top - spec["device_gap"] - spec["headline_top"] - caption_height(spec, entry)) // 2
    y = compose.draw_lines(draw, headline[1], headline[0], headline[2], top, width, compose.HEADLINE_COLOR)
    compose.draw_lines(draw, subhead[1], subhead[0], subhead[2], y + spec["gap"], width, compose.SUBHEAD_COLOR)
    room_width = width - 2 * max(spec["bottom"], 48)
    room_height = height - device_top - spec["bottom"]
    device = compose.framed(path, None, room_width)
    scale = min(1.0, room_height / device.height)
    device = device.resize((round(device.width * scale), round(device.height * scale)), Image.LANCZOS)
    compose.paste_with_shadow(canvas, device, ((width - device.width) // 2, device_top))
    image = canvas.convert("RGB")
    if image.size != spec["size"]:
        sys.exit(f"{entry['screen']}: composed {image.size}, expected {spec['size']}")
    return image


def compose_duo(captions, locale, raw_dir):
    language = language_of(locale)
    stories = [{**story, "language": language} for story in captions_for(captions, locale if language != "en" else "en-US")]
    device_tops = {}
    for state, spec in SIZES.items():
        heights = [caption_height(spec, story) for story in stories if story["state"] == state]
        if heights:
            device_tops[state] = spec["headline_top"] + max(heights) + spec["device_gap"]
    out = os.path.join(ROOT, "marketing/appstore/duo", locale)
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(out):
        if name.endswith(".png"):
            os.remove(os.path.join(out, name))
    for index, story in enumerate(stories, start=1):
        target = os.path.join(out, f"{index:02d}-{story['screen']}.png")
        panel(story, raw_dir, device_tops).save(target, optimize=True)
        print(target, flush=True)


def icon(size):
    """The app icon with the system's continuous corner, at `size` pixels."""
    source = Image.open(os.path.join(ROOT, "ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")).convert("RGBA")
    source = source.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=round(size * 4 * 0.2237), fill=255)
    source.putalpha(mask.resize((size, size), Image.LANCZOS))
    return source


def header_text(locale):
    """The subtitle the App Store shows under the name, in the locale's words, or English where it cannot be shaped."""
    chosen = "en-US" if locale in UNSHAPED else locale
    return json.load(open(os.path.join(ROOT, f"store/metadata/ios/app-info/{chosen}.json"), encoding="utf-8"))["subtitle"], chosen


def scaled(image, height):
    return image.resize((round(image.width * height / image.height), round(height)), Image.LANCZOS)


def compose_header(locale, raw_dir):
    """The Header and the Search Results images: everything that matters sits in the middle 70 % of the width and above
    the lower fifth, where the App Store may lay its own name and button over the art."""
    language = language_of(locale)
    subtitle, text_locale = header_text(locale)
    compose.LOCALE = text_locale
    width = HEADER_SIZE[0]
    out = os.path.join(ROOT, "marketing/appstore/header", locale)
    os.makedirs(out, exist_ok=True)

    inner_home = compose.framed(os.path.join(raw_dir, f"inner-landscape-{language}", "01-home.png"), None, 2600)
    outer_detail = compose.framed(os.path.join(raw_dir, f"outer-portrait-{language}", "03-detail.png"), None, 900)

    canvas = compose.background(HEADER_SIZE)
    draw = ImageDraw.Draw(canvas)
    mark = icon(300)
    name_face = compose.font("Bold", 230)
    name_width = name_face.getlength("Crucible")
    row_width = mark.width + 70 + name_width
    left = round((width - row_width) / 2)
    canvas.alpha_composite(mark, (left, 230))
    cap = name_face.getbbox("C")
    draw.text((left + mark.width + 70, 230 + (mark.height - (cap[3] - cap[1])) / 2 - cap[1]), "Crucible", font=name_face, fill=compose.HEADLINE_COLOR)
    face, lines, leading = compose.fit(subtitle, "Medium", (120, 84, 140), 3000, 1)
    compose.draw_lines(draw, lines, face, leading, 620, width, compose.SUBHEAD_COLOR)

    device_top = 880
    inner = scaled(inner_home, 1560)
    outer = scaled(outer_detail, 1760)
    gap = -40
    total = inner.width + outer.width + gap
    x = (width - total) // 2
    compose.paste_with_shadow(canvas, inner, (x, device_top + 120))
    compose.paste_with_shadow(canvas, outer, (x + inner.width + gap, device_top))
    canvas.convert("RGB").save(os.path.join(out, "header.png"), optimize=True)

    search = compose.background(HEADER_SIZE)
    draw = ImageDraw.Draw(search)
    face, lines, leading = compose.fit(subtitle, "Bold", (190, 120, 220), 3600, 1)
    compose.draw_lines(draw, lines, face, leading, 250, width, compose.HEADLINE_COLOR)
    inner_offer = scaled(compose.framed(os.path.join(raw_dir, f"inner-landscape-{language}", "04c-essentials-offer.png"), None, 2800), 1800)
    outer_home = scaled(compose.framed(os.path.join(raw_dir, f"outer-portrait-{language}", "01-home.png"), None, 900), 1920)
    overlap = 60
    total = inner_offer.width + outer_home.width - overlap
    x = (width - total) // 2
    compose.paste_with_shadow(search, inner_offer, (x, 680))
    compose.paste_with_shadow(search, outer_home, (x + inner_offer.width - overlap, 620))
    search.convert("RGB").save(os.path.join(out, "search.png"), optimize=True)
    for name in ("header.png", "search.png"):
        with Image.open(os.path.join(out, name)) as image:
            if image.size != HEADER_SIZE or image.mode != "RGB":
                sys.exit(f"{locale}/{name}: {image.size} {image.mode}, expected {HEADER_SIZE} RGB")
        print(os.path.join(out, name), flush=True)


def main():
    args = sys.argv[1:]
    raw_dir = os.path.join(ROOT, "marketing/shots/out/duo")
    locales = STORE_LOCALES
    if "--raw" in args:
        at = args.index("--raw")
        raw_dir = args[at + 1]
        del args[at:at + 2]
    if "--locale" in args:
        at = args.index("--locale")
        locales = [args[at + 1]]
        del args[at:at + 2]
    kinds = args or ["duo", "header"]
    captions = json.load(open(os.path.join(HERE, "captions.json"), encoding="utf-8"))
    for locale in locales:
        compose.LOCALE = locale if language_of(locale) != "en" else None
        if "duo" in kinds:
            compose_duo(captions, locale, raw_dir)
        if "header" in kinds:
            compose_header(locale, raw_dir)


if __name__ == "__main__":
    main()
