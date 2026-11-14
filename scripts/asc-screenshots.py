#!/usr/bin/env python3
"""Upload Crucible's App Store screenshots: the iPhone 6.9-inch, iPhone Duo and iPad 13-inch sets on the iOS version and the Apple TV
set on the tvOS version.

Sources: marketing/appstore/iphone/*.png (1320x2868) and marketing/appstore/ipad/*.png (2752x2064), both composed by
marketing/store/compose.py, and marketing/appstore/tvos/*.png (3840x2160), uploaded in file-name order.
Each set is read back afterwards and must hold the expected number of COMPLETE screenshots.

With --locales=all, every localized iPhone set in marketing/appstore/l10n/<locale>/iphone is uploaded to that locale too;
locales without their own set show the en-US screenshots.

The iPhone Duo set is marketing/appstore/duo/<locale>/*.png from marketing/store/compose_duo.py: ten screenshots across the four
Duo sizes, one folder per locale (en-US first, the rest with --locales=all).

Usage: python3 scripts/asc-screenshots.py [--only=iphone|ipad|duo|tvos] [--locales=all] [--skip-existing]
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.realpath(os.path.join(ROOT, "marketing/appstore"))
SPEC = json.load(open(os.path.join(ROOT, "docs/asc-metadata.json")))
VERSIONS = {"iphone": SPEC["versions"]["IOS"], "ipad": SPEC["versions"]["IOS"], "duo": SPEC["versions"]["IOS"], "tvos": SPEC["versions"]["TV_OS"]}
DEVICES = {
    "iphone": ("IPHONE_67", "APP_IPHONE_67"),
    "duo": ("IPHONE_DUO", "APP_IPHONE_DUO"),
    "ipad": ("IPAD_PRO_3GEN_129", "APP_IPAD_PRO_3GEN_129"),
    "tvos": ("APPLE_TV", "APP_APPLE_TV"),
}


def asc(*args):
    result = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True)
    body = result.stdout[result.stdout.find("{"):] if "{" in result.stdout else result.stdout
    if result.returncode != 0:
        sys.exit(f"asc {' '.join(args)} failed:\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}")
    return json.loads(body) if body.strip().startswith("{") else result.stdout


def localization(version_id, locale):
    rows = asc("localizations", "list", "--version", version_id).get("data", [])
    return next(r["id"] for r in rows if r["attributes"]["locale"] == locale)


def upload(kind, replace, locale="en-US"):
    if kind == "duo":
        source = os.path.join(SHOTS, "duo", locale)
    else:
        source = os.path.join(SHOTS, kind) if locale == "en-US" else os.path.join(SHOTS, "l10n", locale, kind)
    expected = len([f for f in os.listdir(source) if f.endswith(".png")])
    loc_id = localization(VERSIONS[kind], locale)
    flags = ["--replace", "--confirm"] if replace else ["--skip-existing"]
    command = ["asc", "screenshots", "upload", "--version-localization", loc_id, "--path", source,
               "--device-type", DEVICES[kind][0], *flags]
    print(f"{kind} {locale}: uploading {expected} screenshots ({' '.join(flags)})", flush=True)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        return f"{kind}: upload failed: {(result.stderr or result.stdout)[-300:].strip()}"
    return verify(kind, loc_id, expected)


def verify(kind, loc_id, expected):
    sets = asc("screenshots", "list", "--version-localization", loc_id).get("sets", [])
    mine = [s for s in sets if s["set"]["attributes"]["screenshotDisplayType"] == DEVICES[kind][1]]
    shots = mine[0].get("screenshots", []) if mine else []
    states = sorted({(s["attributes"].get("assetDeliveryState") or {}).get("state") for s in shots})
    if len(shots) != expected or states != ["COMPLETE"]:
        return f"{kind}: {len(shots)} screenshots {states}, expected {expected} COMPLETE"
    print(f"{kind}: {len(shots)} COMPLETE", flush=True)
    return None


def main():
    only = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--only=")), None)
    replace = "--skip-existing" not in sys.argv
    failures = [message for kind in VERSIONS if not only or kind == only if (message := upload(kind, replace))]
    if "--locales=all" in sys.argv and (not only or only == "iphone"):
        localized = sorted(os.listdir(os.path.join(SHOTS, "l10n"))) if os.path.isdir(os.path.join(SHOTS, "l10n")) else []
        failures += [message for locale in localized if (message := upload("iphone", replace, locale))]
    if "--locales=all" in sys.argv and (not only or only == "duo"):
        duo = os.path.join(SHOTS, "duo")
        localized = sorted(name for name in os.listdir(duo) if name != "en-US") if os.path.isdir(duo) else []
        failures += [message for locale in localized if (message := upload("duo", replace, locale))]
    if failures:
        sys.exit("!! " + "\n!! ".join(failures))
    print("all sets verified", flush=True)


if __name__ == "__main__":
    main()
