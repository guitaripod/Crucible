#!/usr/bin/python3
"""Compose Crucible's iPhone Duo screenshots and its product page Header and Search Results images.

Usage: marketing/store/compose_duo.py [duo] [header] [--locale LOCALE] [--raw DIR] [--guides]

duo: the ten Duo screenshots, one story each from captions.json's "duo" list, at the size of the display it was
captured on (inner landscape 2853x2007, inner portrait 2007x2853, outer portrait 1398x2034, outer landscape
2034x1398), into marketing/appstore/duo/<locale>. Captures come from DIR/<state>-<language>/<screen>.png, as
marketing/shots/duo-run.sh writes them for each Duo state; every capture is set into Apple's Duo bezel by the
`frames` CLI and placed on the ember gradient under its localized caption, as the iPhone set is. The type is set
to be read at the size the store shows a screenshot, and the device fills the panel's width.

header: the product page Header (3840x1646) and the Search Results image (3840x2560), each made for its own
placement, into marketing/appstore/header/<locale> as header.png and search.png. Apple crops both differently on every
device and promises only an art safe area in the middle (creative assets specifications, App Store Connect Help), so
the phrase from captions.json's "creative" and the top of the iPhone that proves it sit inside that box, and four more
iPhones run out of it as atmosphere. The phones come from marketing/shots/out/raw-dark[-language] (run.sh), in the
frames CLI's bezel. --guides also draws the safe area, into header-guides.png and search-guides.png, for looking at.
Arabic and Thai, which this pipeline cannot shape, use the English text, as their screenshots do.
"""

import json
import os
import sys

from PIL import Image, ImageDraw

import compose

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STORE_LOCALES = ["en-US", "ar-SA", "de-DE", "es-ES", "fr-FR", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant", "sv", "da", "no", "fi"]
UNSHAPED = {"ar-SA", "th"}

SIZES = {
    "inner-landscape": {"size": (2853, 2007), "headline": (168, 118, 190), "subhead": (84, 62, 104), "headline_top": 112, "gap": 34, "text_margin": 190, "device_gap": 78, "side": 96},
    "inner-portrait": {"size": (2007, 2853), "headline": (170, 122, 194), "subhead": (84, 62, 104), "headline_top": 150, "gap": 40, "text_margin": 110, "device_gap": 92, "side": 84},
    "outer-portrait": {"size": (1398, 2034), "headline": (124, 90, 142), "subhead": (62, 46, 78), "headline_top": 112, "gap": 30, "text_margin": 70, "device_gap": 72, "side": 62},
    "outer-landscape": {"size": (2034, 1398), "headline": (128, 94, 146), "subhead": (64, 48, 80), "headline_top": 84, "gap": 26, "text_margin": 150, "device_gap": 58, "side": 70},
}
BOTTOM = 56
MOST_CUT = 0.3


def language_of(locale):
    """The capture language for an App Store locale: its own where the app is localized, English elsewhere."""
    return compose.LANGUAGE.get(locale, "en")


def captions_for(captions, locale):
    """The Duo stories with the locale's headline and subhead: the iPhone set's for the same screen, or the story's
    own where the iPhone set has no such screen."""
    text = captions["l10n"].get(locale, {}) if locale != "en-US" else {}
    stories = []
    for entry in captions["duo"]:
        base = next((item for item in captions["iphone"] if item["screen"] == entry["screen"]), {})
        stories.append({**base, **entry, **text.get(entry["screen"], {})})
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
    """One Duo screenshot: the caption centred in the band above the device, the device as wide as the panel and
    running off its lower edge so the screen is large enough to read, unless the story is marked `whole`, whose
    point sits at the bottom of the screen. No more than `MOST_CUT` of a device is ever cut, or the story's own
    `cut` where what it is about sits lower on the screen."""
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
    device = compose.framed(path, None, width - 2 * spec["side"])
    room = height - device_top
    shown = room - BOTTOM if entry.get("whole") else room / (1 - entry.get("cut", MOST_CUT))
    scale = min(1.0, shown / device.height)
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


CREATIVE = {
    "header": {
        "size": (3840, 1646), "safe": (1097, 493, 1646, 661),
        "headline": (150, 100, 168), "subline": (76, 54, 92), "gap": 20, "device_gap": 40,
        "hero": 880, "side": 770, "far": 680, "step": 80, "spacing": 74,
    },
    "search": {
        "size": (3840, 2560), "safe": (836, 765, 2168, 1030),
        "headline": (236, 150, 262), "subline": (116, 80, 140), "gap": 36, "device_gap": 70,
        "hero": 1280, "side": 1100, "far": 960, "step": 120, "spacing": 96,
    },
}
CREATIVE_SCREENS = ["02b-library-settled", "04c-essentials-offer", "15-what-to-watch", "01-home", "07c-share-preview"]
CREATIVE_DIM = (1.0, 0.86, 0.7)
REQUEST_FIELD_BOTTOM = 0.385
SMALLEST_HERO = 0.8
SMALLEST_TYPE = 0.7


def creative_text(captions, locale):
    """The phrase and the line under it for the Header and Search images, in the locale's words, or English where
    the text cannot be shaped."""
    if locale in UNSHAPED or locale == "en-US":
        return captions["creative"], None
    return {**captions["creative"], **captions["l10n"].get(locale, {}).get("creative", {})}, locale


def one_line(text, weight, spec, width):
    """The text on one line, at a smaller size when it has to be and never under `SMALLEST_TYPE` of the size asked
    for; on two lines at the full size only when that is not enough. A second line pushes the phone out of the
    safe area, so a smaller line is the better trade."""
    size, minimum, leading = spec
    floor = max(minimum, round(size * SMALLEST_TYPE))
    face, lines, scaled = compose.fit(text, weight, (size, floor, leading), width, 1)
    if len(lines) == 1 and face.getlength(lines[0]) <= width:
        return face, lines, scaled
    return compose.fit(text, weight, spec, width, 2)


def phone_raw(language):
    return os.path.join(ROOT, "marketing/shots/out", "raw-dark" if language == "en" else f"raw-dark-{language}")


def dimmed(device, factor):
    """The device darkened towards the backdrop, so the one in the middle is the one that is looked at."""
    if factor >= 1:
        return device
    red, green, blue, alpha = device.split()
    scale = lambda channel: channel.point(lambda value: round(value * factor))
    return Image.merge("RGBA", (scale(red), scale(green), scale(blue), alpha))


def compose_creative(kind, captions, locale, guides=False):
    """One product page image. Apple shows it cropped differently on every device and lays its own controls over the
    edges, and promises only the art safe area: the phrase and the line under it sit inside that box with the top of
    the phone that proves them down to its request field (`REQUEST_FIELD_BOTTOM` of the phone's width below its top),
    and the other phones run out of it as atmosphere, each darker the further out it is. The phones run off the
    bottom edge, where the App Store sets the app's name and button; long words make every phone a little smaller."""
    spec = CREATIVE[kind]
    width, height = spec["size"]
    left, top, safe_width, safe_height = spec["safe"]
    text, text_locale = creative_text(captions, locale)
    compose.LOCALE = text_locale
    canvas = compose.background(spec["size"])
    draw = ImageDraw.Draw(canvas)
    room = safe_width - 60
    headline = one_line(text["headline"], "Bold", spec["headline"], room)
    subline = one_line(text["subline"], "Medium", spec["subline"], room)
    y = compose.draw_lines(draw, headline[1], headline[0], headline[2], top + 6, width, compose.HEADLINE_COLOR)
    y = compose.draw_lines(draw, subline[1], subline[0], subline[2], y + spec["gap"], width, compose.SUBHEAD_COLOR)
    device_top = y + spec["device_gap"] - round(subline[2] * 0.2)
    shrink = min(1.0, (top + safe_height - device_top) / (REQUEST_FIELD_BOTTOM * spec["hero"]))
    if shrink < SMALLEST_HERO:
        sys.exit(f"{locale}/{kind}: the words leave no room in the safe area for the phone down to its request field (phone starts at {device_top})")

    raw = phone_raw(language_of(locale))
    widths = [round(spec[name] * shrink) for name in ("far", "side", "hero", "side", "far")]
    order = [0, 4, 1, 3, 2]
    centre = width // 2
    offsets = {2: 0}
    offsets[1] = -(widths[2] + widths[1]) // 2 - spec["spacing"]
    offsets[3] = -offsets[1]
    offsets[0] = offsets[1] - (widths[1] + widths[0]) // 2 - spec["spacing"]
    offsets[4] = -offsets[0]
    for index in order:
        rank = abs(index - 2)
        device = dimmed(compose.framed(os.path.join(raw, CREATIVE_SCREENS[index] + ".png"), "Black", widths[index]), CREATIVE_DIM[rank])
        x = centre + offsets[index] - device.width // 2
        compose.paste_with_shadow(canvas, device, (x, device_top + rank * spec["step"]))
    image = canvas.convert("RGB")
    if guides:
        overlay = ImageDraw.Draw(image)
        overlay.rectangle((left, top, left + safe_width, top + safe_height), outline=(0, 255, 120), width=6)
    return image


def compose_header(captions, locale, guides=False):
    """The Header (3840x1646) and the Search Results image (3840x2560) of one listing language, each made for its own
    placement instead of one image cropped two ways."""
    out = os.path.join(ROOT, "marketing/appstore/header", locale)
    os.makedirs(out, exist_ok=True)
    for kind in ("header", "search"):
        image = compose_creative(kind, captions, locale, guides)
        target = os.path.join(out, f"{kind}{'-guides' if guides else ''}.png")
        image.save(target, optimize=True)
        with Image.open(target) as saved:
            if saved.size != CREATIVE[kind]["size"] or saved.mode != "RGB":
                sys.exit(f"{locale}/{kind}: {saved.size} {saved.mode}, expected {CREATIVE[kind]['size']} RGB")
        print(target, flush=True)


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
    guides = "--guides" in args
    args = [arg for arg in args if arg != "--guides"]
    kinds = args or ["duo", "header"]
    captions = json.load(open(os.path.join(HERE, "captions.json"), encoding="utf-8"))
    for locale in locales:
        compose.LOCALE = locale if language_of(locale) != "en" else None
        if "duo" in kinds:
            compose_duo(captions, locale, raw_dir)
        if "header" in kinds:
            compose_header(captions, locale, guides)


if __name__ == "__main__":
    main()
