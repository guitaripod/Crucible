#!/usr/bin/env python3
"""Lay framed TV screenshots out as a grid collage on a dark canvas with soft shadows and a warm glow."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

EMBER = (255, 159, 10)
BASE_TOP = (17, 17, 22)
BASE_BOTTOM = (5, 5, 8)
GLOW_STRENGTH = 0.20
SHADOW_ALPHA = 0.62
SHADOW_BLUR_FRACTION = 0.016
SHADOW_DROP_FRACTION = 0.012
HEADER_FRACTION = 0.17
BOLD_FONTS = ["/usr/share/fonts/TTF/Roboto-Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"]
REGULAR_FONTS = ["/usr/share/fonts/TTF/Roboto-Regular.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf"]


def background(size, columns):
    """A vertical charcoal gradient with an ember glow behind each column, built small and enlarged so it stays smooth."""
    width, height = size
    scale = 8
    small_w, small_h = width // scale, height // scale
    y = np.linspace(0, 1, small_h)[:, None, None]
    base = np.array(BASE_TOP) * (1 - y) + np.array(BASE_BOTTOM) * y
    base = np.broadcast_to(base, (small_h, small_w, 3)).copy()
    xs = np.linspace(0, 1, small_w)[None, :]
    ys = np.linspace(0, 1, small_h)[:, None]
    for column in range(columns):
        center_x = (column + 0.5) / columns
        distance = np.sqrt(((xs - center_x) * width / height) ** 2 + (ys - 0.5) ** 2)
        falloff = np.clip(1 - distance / 0.62, 0, 1) ** 2.2
        base += falloff[:, :, None] * GLOW_STRENGTH * (np.array(EMBER) - base)
    image = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8)).resize(size, Image.BICUBIC)
    noise = Image.effect_noise(size, 5)
    return Image.merge("RGB", [ImageChops.add(channel, noise, 1, -128) for channel in image.split()])


def shadow_of(tile, blur, drop):
    """The tile's silhouette, blurred and pushed down, as a black layer the size of the tile plus its spread."""
    margin = blur * 3
    layer = Image.new("L", (tile.width + 2 * margin, tile.height + 2 * margin), 0)
    layer.paste(tile.getchannel("A"), (margin, margin + drop))
    layer = layer.point(lambda value: int(value * SHADOW_ALPHA)).filter(ImageFilter.GaussianBlur(blur))
    black = Image.new("RGBA", layer.size, (0, 0, 0, 255))
    black.putalpha(layer)
    return black, margin


def font(candidates, size):
    """The first installed font of the list at `size`."""
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    raise SystemExit(f"none of these fonts is installed: {', '.join(candidates)}")


def logo(icon_dir, height):
    """The app icon's glow and crystal layers stacked on transparency, scaled to `height`."""
    layers = [Image.open(next(icon_dir.glob(f"{name}.imagestacklayer/Content.imageset/*@1x.png"))).convert("RGBA") for name in ("Middle", "Front")]
    stacked = Image.alpha_composite(layers[0], layers[1])
    stacked = stacked.crop(layers[0].getchannel("A").getbbox())
    return stacked.resize((round(stacked.width * height / stacked.height), height), Image.LANCZOS)


def header(width, height, icon_dir, title, tagline):
    """The lockup: crystal, name and tagline, left aligned on a transparent band."""
    band = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    mark = logo(icon_dir, round(height * 0.92))
    band.alpha_composite(mark, (0, (height - mark.height) // 2))
    name_font = font(BOLD_FONTS, round(height * 0.6))
    tagline_font = font(REGULAR_FONTS, round(height * 0.17))
    draw = ImageDraw.Draw(band)
    left = mark.width + round(height * 0.04)
    name_box = draw.textbbox((left, 0), title, font=name_font)
    tagline_box = draw.textbbox((left, 0), tagline, font=tagline_font)
    gap = round(height * 0.05)
    block = (name_box[3] - name_box[1]) + gap + (tagline_box[3] - tagline_box[1])
    top = (height - block) // 2
    draw.text((left, top - name_box[1]), title, font=name_font, fill=(246, 244, 240, 255))
    draw.text((left, top + (name_box[3] - name_box[1]) + gap - tagline_box[1]), tagline, font=tagline_font, fill=(190, 184, 176, 255))
    return band


def compose(tiles, columns, gutter, margin, banner=None):
    """Places the tiles row by row, equal size, under the optional banner, on a canvas sized to hold them."""
    rows = -(-len(tiles) // columns)
    tile_w, tile_h = tiles[0].size
    banner_h = banner.height + margin if banner else 0
    size = (columns * tile_w + (columns - 1) * gutter + 2 * margin, banner_h + rows * tile_h + (rows - 1) * gutter + 2 * margin)
    canvas = background(size, columns).convert("RGBA")
    if banner:
        canvas.alpha_composite(banner, (margin, margin))
    blur = round(tile_w * SHADOW_BLUR_FRACTION)
    drop = round(tile_w * SHADOW_DROP_FRACTION)
    for index, tile in enumerate(tiles):
        left = margin + (index % columns) * (tile_w + gutter)
        top = margin + banner_h + (index // columns) * (tile_h + gutter)
        shadow, spread = shadow_of(tile, blur, drop)
        canvas.alpha_composite(shadow, (left - spread, top - spread))
        canvas.alpha_composite(tile, (left, top))
    return canvas.convert("RGB")


def main():
    parser = argparse.ArgumentParser(description="Compose framed TV screenshots into a collage.")
    parser.add_argument("tiles", nargs="+", type=Path, help="framed screenshots, in reading order")
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--columns", type=int, default=2)
    parser.add_argument("--tile-width", type=int, default=3600, help="each framed tile is scaled to this width")
    parser.add_argument("--gutter", type=int, default=140)
    parser.add_argument("--margin", type=int, default=160)
    parser.add_argument("--web-width", type=int, default=4096, help="also write <output>-web.png at this width (0 to skip)")
    parser.add_argument("--icon-dir", type=Path, help="the app icon image stack (App Icon - Large.imagestack) for the header")
    parser.add_argument("--title", default="Crucible")
    parser.add_argument("--tagline", default="")
    args = parser.parse_args()

    tiles = []
    for path in args.tiles:
        image = Image.open(path).convert("RGBA")
        height = round(image.height * args.tile_width / image.width)
        tiles.append(image.resize((args.tile_width, height), Image.LANCZOS))
    banner = None
    if args.icon_dir:
        banner = header(args.columns * args.tile_width + (args.columns - 1) * args.gutter, round(args.tile_width * HEADER_FRACTION), args.icon_dir, args.title, args.tagline)
    collage = compose(tiles, args.columns, args.gutter, args.margin, banner)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    collage.save(args.output, optimize=True)
    print(f"{args.output} {collage.width}x{collage.height} {args.output.stat().st_size / 1e6:.1f} MB")
    if args.web_width:
        web = collage.resize((args.web_width, round(collage.height * args.web_width / collage.width)), Image.LANCZOS)
        web_path = args.output.with_name(args.output.stem + "-web.png")
        web.save(web_path, optimize=True)
        print(f"{web_path} {web.width}x{web.height} {web_path.stat().st_size / 1e6:.1f} MB")
        jpeg_path = web_path.with_suffix(".jpg")
        web.save(jpeg_path, quality=92, subsampling=0, optimize=True)
        print(f"{jpeg_path} {jpeg_path.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
