#!/usr/bin/env python3
"""Exports the mock's fictional catalogue as the bundle the in-app demo library serves.

Writes Sources/CrucibleDemo/Data (override with --out):

    library.json         the catalogue: movies, shows, seasons, episodes, cast, watch state as time offsets
    images/              posters (<= 400x600), backdrops (<= 1280x720), episode stills (<= 480x270), cast avatars (<= 200x200)
    video/clip.mp4       one short H.264/AAC clip, served as the direct-play part of every title
    video/hls/           the same clip cut into 2 second fMP4 segments, served as the transcode of every title

Needs Pillow, ffmpeg and the artwork in marketing/mock/assets (python3 art.py regenerates it).

    python3 export_demo.py                  everything
    python3 export_demo.py --skip-video     catalogue and images only
    python3 export_demo.py --skip-images    catalogue and video only
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

from PIL import Image

import library

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
DEFAULT_OUT = os.path.normpath(os.path.join(HERE, "..", "..", "Sources", "CrucibleDemo", "Data"))

REFERENCE_NOW = 2000000000
DEMO_MACHINE_ID = "d3a41e7b5c9f4a2e8b60f1c7d5e93a24"
DEMO_SECTIONS = ("1", "2", "3")
CLIP_SECONDS = 30
HLS_SEGMENT_SECONDS = 2
CLIP_BACKDROP = "backdrop_1001.jpg"
CAPTION_FONT = "/usr/share/fonts/liberation/LiberationSans-Bold.ttf"
EXTRA_WATCHED_DOCUMENTARIES = {"The Last Lighthouse": 21 * 86400}

POSTER_BOX, BACKDROP_BOX, STILL_BOX, AVATAR_BOX = (400, 600), (1280, 720), (480, 270), (200, 200)
POSTER_QUALITY, BACKDROP_QUALITY, STILL_QUALITY, AVATAR_QUALITY = 72, 62, 68, 74

TIME_FIELDS = {"addedAt": "addedAgo", "updatedAt": "updatedAgo", "lastViewedAt": "lastViewedAgo"}
INTERNAL_FIELDS = {"_style", "_genres", "_directors", "_writers", "_cast", "_kind", "_seasons", "_end", "_episodes", "_show",
                   "_season", "_media", "_markers", "_related"}


def build_library():
    """The mock's library at a fixed instant, so every timestamp in it can be turned into seconds before that instant."""
    library.Library._build_history = lambda self: setattr(self, "history", [])
    lib = library.Library(now=REFERENCE_NOW)
    for title, ago in EXTRA_WATCHED_DOCUMENTARIES.items():
        item = next(m for m in lib.movies if m["title"] == title)
        item["viewCount"] = 1
        item["lastViewedAt"] = REFERENCE_NOW - ago
    return lib


def public_fields(item):
    """The Plex fields of an item with its three timestamps turned into seconds before now."""
    out = {}
    for key, value in item.items():
        if key in INTERNAL_FIELDS:
            continue
        if key in TIME_FIELDS:
            out[TIME_FIELDS[key]] = REFERENCE_NOW - int(value)
        else:
            out[key] = value
    return out


def media_facts(item):
    media = item["_media"][0]
    stream = media["Part"][0]["Stream"][0]
    return {"width": media["width"], "height": media["height"], "hdr": "HDR" in stream["displayTitle"],
            "size": media["Part"][0]["size"]}


def export_item(lib, item):
    out = {"kind": item["_kind"], "fields": public_fields(item), "genres": item.get("_genres", []),
           "directors": item.get("_directors", []), "writers": item.get("_writers", []),
           "cast": lib._roles(item.get("_cast", [])), "related": item.get("_related", [])}
    if "_media" in item:
        out["media"] = media_facts(item)
    if item["_kind"] == "show":
        out["endYear"] = item.get("_end")
    if item["_kind"] == "season":
        out["show"] = item["_show"]
    if item["_kind"] == "episode":
        out["show"] = item["_show"]
        out["season"] = item["_season"]
    return out


def export_catalogue(lib):
    items = []
    for movie in lib.movies:
        items.append(export_item(lib, movie))
    for show in lib.shows:
        items.append(export_item(lib, show))
        for season in show["_seasons"]:
            items.append(export_item(lib, season))
            items.extend(export_item(lib, episode) for episode in season["_episodes"])
    sections = [{"id": k, "title": library.SECTIONS[k][0], "type": library.SECTIONS[k][1]} for k in DEMO_SECTIONS]
    return {"version": 1, "machineIdentifier": DEMO_MACHINE_ID, "sections": sections,
            "genres": [{"id": library.GENRE_ID[g], "title": g} for g in library.GENRES],
            "items": items, "onDeck": lib.on_deck, "clipSeconds": CLIP_SECONDS}


def artwork_names(lib):
    """Every artwork file the catalogue references, as asset file names."""
    names = set()
    for item in lib.items.values():
        rk = item["ratingKey"]
        kind = item["_kind"]
        if kind == "episode":
            names.add(f"still_{rk}.jpg")
        else:
            names.add(f"poster_{rk}.jpg")
        if kind in ("movie", "show"):
            names.add(f"backdrop_{rk}.jpg")
        for name, _ in item.get("_cast", []):
            names.add(f"actor_{library.slug(name)}.jpg")
    return sorted(names)


def shrink(source, target, box, quality):
    with Image.open(source) as image:
        image = image.convert("RGB")
        image.thumbnail(box, Image.LANCZOS)
        image.save(target, "JPEG", quality=quality, optimize=True, progressive=True)


def export_images(lib, out):
    images = os.path.join(out, "images")
    shutil.rmtree(images, ignore_errors=True)
    os.makedirs(images)
    rules = {"poster_": (POSTER_BOX, POSTER_QUALITY), "backdrop_": (BACKDROP_BOX, BACKDROP_QUALITY),
             "still_": (STILL_BOX, STILL_QUALITY), "actor_": (AVATAR_BOX, AVATAR_QUALITY)}
    names = artwork_names(lib)
    for name in names:
        source = os.path.join(ASSETS, name)
        if not os.path.isfile(source):
            sys.exit(f"missing artwork {source}; run python3 art.py")
        box, quality = next(rule for prefix, rule in rules.items() if name.startswith(prefix))
        shrink(source, os.path.join(images, name), box, quality)
    return len(names)


def run(*args):
    subprocess.run(args, check=True)


def export_video(out):
    """One clip with a quiet synthesised pad and a corner caption, then the same clip cut for HLS."""
    video = os.path.join(out, "video")
    shutil.rmtree(video, ignore_errors=True)
    hls = os.path.join(video, "hls")
    os.makedirs(hls)
    clip = os.path.join(video, "clip.mp4")
    caption = (f"drawtext=fontfile={CAPTION_FONT}:text='Crucible demo footage  %{{eif\\:t\\:d}}s':fontcolor=white@0.85:"
               "fontsize=26:box=1:boxcolor=black@0.45:boxborderw=12:x=36:y=h-th-36")
    motion = ("scale=1600:-1,zoompan=z='1.0+0.0004*on':x='iw/2-(iw/zoom/2)+on*0.35':y='ih/2-(ih/zoom/2)':d=1:s=1280x720:fps=25,"
              f"{caption},format=yuv420p")
    pad = ("0.10*sin(2*PI*110*t)+0.07*sin(2*PI*164.81*t)+0.06*sin(2*PI*220*t)*(0.6+0.4*sin(2*PI*0.2*t))"
           "+0.03*sin(2*PI*329.63*t)*(0.5+0.5*sin(2*PI*0.13*t))")
    run("ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-loop", "1", "-framerate", "25", "-i", os.path.join(ASSETS, CLIP_BACKDROP),
        "-f", "lavfi", "-i", f"aevalsrc='{pad}':s=48000:c=stereo",
        "-vf", motion, "-af", f"afade=t=in:d=1,afade=t=out:st={CLIP_SECONDS - 1}:d=1",
        "-t", str(CLIP_SECONDS), "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-level", "3.1", "-crf", "27",
        "-maxrate", "900k", "-bufsize", "1800k", "-r", "25", "-g", "50", "-keyint_min", "50", "-sc_threshold", "0",
        "-c:a", "aac", "-b:a", "64k", "-ac", "2", "-ar", "48000", "-movflags", "+faststart", clip)
    run("ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", clip, "-c", "copy", "-f", "hls",
        "-hls_time", str(HLS_SEGMENT_SECONDS), "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
        "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", os.path.join(hls, "seg%02d.m4s"),
        os.path.join(hls, "index.m3u8"))


def directory_size(path):
    return sum(os.path.getsize(os.path.join(root, f)) for root, _, files in os.walk(path) for f in files)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--skip-video", action="store_true")
    parser.add_argument("--skip-images", action="store_true")
    args = parser.parse_args()
    lib = build_library()
    os.makedirs(args.out, exist_ok=True)
    catalogue = export_catalogue(lib)
    with open(os.path.join(args.out, "library.json"), "w") as handle:
        json.dump(catalogue, handle, separators=(",", ":"), sort_keys=True)
    print(f"library.json: {len(catalogue['items'])} items")
    if not args.skip_images:
        print(f"images: {export_images(lib, args.out)} files")
    if not args.skip_video:
        export_video(args.out)
    total = directory_size(args.out)
    print(f"resources: {total / 1048576:.2f} MB")
    if total > 12 * 1048576:
        sys.exit("the bundle is over 12 MB")


if __name__ == "__main__":
    main()
