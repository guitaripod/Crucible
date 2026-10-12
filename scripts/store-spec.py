#!/usr/bin/env python3
"""Derive the root-level XcodeGen spec that buildvm archives for the App Store.

buildvm stages a whole checkout, runs `xcodegen generate` on a project.yml at its root and archives a scheme. The iPhone and
Apple TV specs live in ios/ and tv/ and use paths relative to those folders, so this rebases every path to the checkout root,
drops the UI test target, writes the bundle's distribution signing onto each app and extension target (Release, scoped to the
device SDK, so the Swift packages are never asked to use a profile) and fills in the SwiftPM package name.

Usage: store-spec.py ios|tv --package-name NAME [--output project.yml]
"""

import argparse
import posixpath
import sys

import yaml

TEAM = "P4DQK6SRKR"
IDENTITY = "Apple Distribution"

PLATFORMS = {
    "ios": {
        "folder": "ios",
        "sdk": "iphoneos*",
        "dropped": [],
        "profiles": {
            "CrucibleApp": "Crucible iOS App Store 2026",
            "CrucibleWidgetsExt": "Crucible Widgets App Store 2026",
        },
        "project": "CrucibleIOS",
    },
    "tv": {
        "folder": "tv",
        "sdk": "appletvos*",
        "dropped": ["CrucibleTVUITests"],
        "profiles": {
            "CrucibleTVApp": "Crucible tvOS App Store 2026",
            "CrucibleTVTopShelf": "Crucible Top Shelf App Store 2026",
        },
        "project": "CrucibleTV",
    },
}


def rebase(path, folder):
    """A path written relative to the platform folder, relative to the checkout root instead."""
    return posixpath.normpath(posixpath.join(folder, path))


def rebase_target(target, folder):
    for source in target.get("sources", []):
        if isinstance(source, dict):
            source["path"] = rebase(source["path"], folder)
    for key in ("info", "entitlements"):
        if key in target:
            target[key]["path"] = rebase(target[key]["path"], folder)


def sign(target, sdk, profile):
    settings = target.setdefault("settings", {})
    release = settings.setdefault("configs", {}).setdefault("Release", {})
    release.update(
        {
            "CODE_SIGN_STYLE": "Manual",
            "DEVELOPMENT_TEAM": TEAM,
            f"CODE_SIGN_IDENTITY[sdk={sdk}]": IDENTITY,
            f"PROVISIONING_PROFILE_SPECIFIER[sdk={sdk}]": profile,
        }
    )


def derive(source, platform, package_name):
    plan = PLATFORMS[platform]
    spec = yaml.safe_load(source.replace("${CRUCIBLE_PACKAGE_NAME}", package_name))
    folder = plan["folder"]
    for package in spec.get("packages", {}).values():
        if "path" in package:
            package["path"] = rebase(package["path"], folder)
    for name in plan["dropped"]:
        spec["targets"].pop(name, None)
    for name, target in spec["targets"].items():
        rebase_target(target, folder)
        if name in plan["profiles"]:
            sign(target, plan["sdk"], plan["profiles"][name])
    for scheme in spec.get("schemes", {}).values():
        targets = scheme.get("build", {}).get("targets", {})
        for name in plan["dropped"]:
            targets.pop(name, None)
        scheme.pop("test", None)
    return spec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=PLATFORMS)
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--output", default="project.yml")
    arguments = parser.parse_args()
    folder = PLATFORMS[arguments.platform]["folder"]
    with open(posixpath.join(folder, "project.yml")) as handle:
        spec = derive(handle.read(), arguments.platform, arguments.package_name)
    with open(arguments.output, "w") as handle:
        yaml.safe_dump(spec, handle, sort_keys=False)
    print(f"{arguments.output}: {PLATFORMS[arguments.platform]['project']} ({arguments.platform}, package {arguments.package_name})")


if __name__ == "__main__":
    sys.exit(main())
