#!/usr/bin/env python3
"""Place Crucible's product page Header and Search Results images on an App Store version.

Sources: marketing/appstore/header/<locale>/header.png and search.png (5244x2950, no alpha), composed by
marketing/store/compose_duo.py header. Each is uploaded to the app's Asset Library as a creative asset and placed on
the version's localization of that locale, replacing the placement already there; a locale without its own images gets
the en-US ones. Placements are read back afterwards. Nothing is submitted: the images go to App Review with the
version, or on their own once a version is approved (`asc review items add --item-type appAssetLibraryImages`).

Usage: python3 scripts/asc-creative.py [--version-id VERSION_ID] [--locale LOCALE]
(the version defaults to docs/asc-metadata.json's IOS version)
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "marketing/appstore/header")
SPEC = json.load(open(os.path.join(ROOT, "docs/asc-metadata.json")))
PLACEMENTS = {"header.png": "PRODUCT_PAGE_HEADER_ASSET", "search.png": "APP_STORE_SEARCH_RESULTS_ASSET"}


def asc(*args):
    result = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"asc {' '.join(args)} failed:\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}")
    body = result.stdout[result.stdout.find("{"):]
    return json.loads(body) if body.strip() else {}


def option(name, default=None):
    return next((sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1]) if arg == name), default)


def upload(path, uploaded):
    """The Asset Library image for `path`, uploaded once per file per run."""
    if path not in uploaded:
        image = asc("asset-library", "images", "upload", "--library-id", SPEC["appId"], "--file", path, "--category", "CREATIVE_ASSETS")
        uploaded[path] = image["data"]["id"]
    return uploaded[path]


def place(localization, placement_type, image_id):
    existing = asc("localizations", "placements", "list", "--localization-id", localization, "--placement-type", placement_type).get("data", [])
    if existing:
        asc("localizations", "placements", "swap", "--localization-id", localization, "--image-id", image_id,
            "--placement-type", placement_type, "--placement-id", existing[0]["id"], "--confirm")
    else:
        asc("localizations", "placements", "create", "--localization-id", localization, "--image-id", image_id,
            "--placement-type", placement_type, "--placement-group", "DEFAULT_PROFILE")
    placed = asc("localizations", "placements", "list", "--localization-id", localization, "--placement-type", placement_type).get("data", [])
    if len(placed) != 1:
        sys.exit(f"{localization} {placement_type}: {len(placed)} placements after placing, expected 1")


def main():
    version = option("--version-id", SPEC["versions"]["IOS"])
    only = option("--locale")
    rows = asc("localizations", "list", "--version", version).get("data", [])
    uploaded = {}
    for row in rows:
        locale = row["attributes"]["locale"]
        if only and locale != only:
            continue
        folder = os.path.join(SOURCE, locale if os.path.isdir(os.path.join(SOURCE, locale)) else "en-US")
        for name, placement_type in PLACEMENTS.items():
            place(row["id"], placement_type, upload(os.path.join(folder, name), uploaded))
        print(f"{locale}: header and search placed from {os.path.basename(folder)}", flush=True)
    print(f"{len(uploaded)} images uploaded", flush=True)


if __name__ == "__main__":
    main()
