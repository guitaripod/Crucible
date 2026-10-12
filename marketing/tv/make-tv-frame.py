#!/usr/bin/env python3
"""Write a `frames` asset folder holding one extra device: a slim-bezel TV for 3840x2160 tvOS screenshots.

The stock Apple Frames pack has no Apple TV, so `frames --assets <folder> shot.png` uses this folder
instead: NewFrames.json maps the 3840 px width to "Apple TV 4K", next to the frame PNG and its
corner mask.
"""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

SCREEN = (3840, 2160)
BEZEL = 44
OUTER_RADIUS = 34
SCREEN_RADIUS = 10
SUPERSAMPLE = 4
NAME = "Apple TV 4K"


def rounded_mask(size, radius):
    """An antialiased rounded rectangle, white inside, drawn at SUPERSAMPLE x and reduced."""
    big = Image.new("L", (size[0] * SUPERSAMPLE, size[1] * SUPERSAMPLE), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, big.width - 1, big.height - 1], radius=radius * SUPERSAMPLE, fill=255)
    return big.resize(size, Image.LANCZOS)


def frame_image():
    """The bezel: near-black glass with a faint lit rim, and a transparent opening for the screen."""
    size = (SCREEN[0] + 2 * BEZEL, SCREEN[1] + 2 * BEZEL)
    outer = rounded_mask(size, OUTER_RADIUS)
    rim = rounded_mask(size, OUTER_RADIUS)
    inset = Image.new("L", size, 0)
    inset.paste(rounded_mask((size[0] - 8, size[1] - 8), OUTER_RADIUS - 4), (4, 4))
    rim = ImageChops.subtract(rim, inset)

    body = Image.new("RGBA", size, (11, 11, 13, 255))
    highlight = Image.new("RGBA", size, (74, 74, 82, 255))
    body.paste(highlight, (0, 0), rim.point(lambda v: int(v * 0.9)))

    opening = Image.new("L", size, 0)
    opening.paste(rounded_mask(SCREEN, SCREEN_RADIUS), (BEZEL, BEZEL))
    body.putalpha(ImageChops.subtract(outer, opening))
    return body


def mask_image():
    """The screenshot's corner mask: the frames CLI reads the red channel as alpha."""
    channel = rounded_mask(SCREEN, SCREEN_RADIUS)
    return Image.merge("RGBA", (channel, channel, channel, Image.new("L", SCREEN, 255)))


def main():
    parser = argparse.ArgumentParser(description="Write the slim-bezel TV asset folder for the frames CLI.")
    parser.add_argument("output", type=Path, help="folder to write; pass it to frames with --assets")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    frame_image().save(args.output / f"{NAME}.png")
    mask_image().save(args.output / f"{NAME}_mask.png")
    (args.output / "version.txt").write_text("4\n")
    entry = {str(SCREEN[0]): {"name": NAME, "mask": "yes", "x": str(BEZEL), "y": str(BEZEL), "physicalHeight": 620}}
    (args.output / "NewFrames.json").write_text(json.dumps(entry, indent=2) + "\n")
    print(f"{args.output}: {NAME} frame {SCREEN[0] + 2 * BEZEL}x{SCREEN[1] + 2 * BEZEL}")


if __name__ == "__main__":
    main()
