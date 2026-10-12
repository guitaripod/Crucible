#!/usr/bin/env python3
"""Lay a framed Apple TV capture and a framed iPhone capture out as one transparent hero image for the landing page.

The TV comes from collage.sh's framing step (a 3928x2248 PNG with its bezel), the phone from the iPhone gallery
(a framed 1470x3000 image from marketing/shots/compose.sh). Both cast a soft shadow; the background stays
transparent so the page's own glow and theme show through.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageFilter

CANVAS_WIDTH = 2400
TV_WIDTH = 2080
PHONE_HEIGHT = 1180
PHONE_OVERLAP = 0.22
SHADOW_BLUR = 38
SHADOW_ALPHA = 0.55
SHADOW_DROP = 26


def fitted(image, width=None, height=None):
    """The image scaled to the given width or height, keeping its proportions."""
    if width is not None:
        height = round(image.height * width / image.width)
    else:
        width = round(image.width * height / image.height)
    return image.resize((width, height), Image.LANCZOS)


def shadow_of(image):
    """A blurred, darkened copy of the image's silhouette."""
    pad = SHADOW_BLUR * 3
    layer = Image.new("RGBA", (image.width + 2 * pad, image.height + 2 * pad), (0, 0, 0, 0))
    alpha = image.getchannel("A").point(lambda v: int(v * SHADOW_ALPHA))
    layer.paste(Image.new("RGBA", image.size, (0, 0, 0, 255)), (pad, pad), alpha)
    return layer.filter(ImageFilter.GaussianBlur(SHADOW_BLUR)), pad


def place(canvas, image, position):
    """Composite the image and its shadow onto the canvas with its top left corner at position."""
    shadow, pad = shadow_of(image)
    canvas.alpha_composite(shadow, (position[0] - pad, position[1] - pad + SHADOW_DROP))
    canvas.alpha_composite(image, position)


def main():
    parser = argparse.ArgumentParser(description="Compose the Apple TV and iPhone hero image.")
    parser.add_argument("tv", type=Path, help="framed Apple TV capture (PNG)")
    parser.add_argument("phone", type=Path, help="framed iPhone capture (PNG or WebP)")
    parser.add_argument("output", type=Path, help="output image; the extension picks the format")
    parser.add_argument("--quality", type=int, default=88, help="WebP quality")
    args = parser.parse_args()

    tv = fitted(Image.open(args.tv).convert("RGBA"), width=TV_WIDTH)
    phone = fitted(Image.open(args.phone).convert("RGBA"), height=PHONE_HEIGHT)

    tv_position = (0, SHADOW_BLUR)
    phone_position = (
        round(tv.width - phone.width * PHONE_OVERLAP * 2.2),
        tv_position[1] + tv.height - round(phone.height * 0.66),
    )
    canvas_height = max(tv_position[1] + tv.height, phone_position[1] + phone.height) + SHADOW_BLUR + SHADOW_DROP
    canvas = Image.new("RGBA", (CANVAS_WIDTH, canvas_height), (0, 0, 0, 0))
    place(canvas, tv, tv_position)
    place(canvas, phone, phone_position)

    bounds = canvas.getbbox()
    canvas = canvas.crop(bounds)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.output, quality=args.quality, method=6)
    print(f"{args.output} {canvas.width}x{canvas.height}")


if __name__ == "__main__":
    main()
