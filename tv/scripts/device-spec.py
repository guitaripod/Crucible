#!/usr/bin/env python3
"""Derive the XcodeGen spec for a device build of the tvOS app from tv/project.yml.

The device variant is the app target alone, signed manually with one development provisioning profile:
no Top Shelf extension, no UI tests, no App Group entitlement (the profile has none), and the bundle id
and team come from the profile so the two cannot disagree.
"""

import argparse
import hashlib
import json
import plistlib
import subprocess
import sys

import yaml

APP_TARGET = "CrucibleTVApp"
DROPPED_TARGETS = ("CrucibleTVTopShelf", "CrucibleTVUITests")
PROJECT_NAME = "CrucibleTVDevice"
INFO_PLIST_PATH = "Generated/Device/CrucibleTV-Info.plist"


def read_profile(path):
    """Decodes a .mobileprovision (a CMS envelope around a property list)."""
    decoded = subprocess.run(["security", "cms", "-D", "-i", path], check=True, capture_output=True).stdout
    return plistlib.loads(decoded)


def bundle_identifier(profile):
    """The explicit bundle id the profile is bound to: its application-identifier without the team prefix."""
    team = profile["TeamIdentifier"][0]
    return profile["Entitlements"]["application-identifier"].removeprefix(team + ".")


def certificate_hashes(profile):
    """SHA-1 of every certificate in the profile, the form `security find-identity` and codesign accept."""
    return [hashlib.sha1(der).hexdigest().upper() for der in profile["DeveloperCertificates"]]


def device_spec(source, profile, identity, build_number):
    """Returns the app-only spec with manual signing scoped to the appletvos SDK on the app target."""
    spec = yaml.safe_load(source)
    spec["name"] = PROJECT_NAME
    for name in DROPPED_TARGETS:
        del spec["targets"][name]
    app = spec["targets"][APP_TARGET]
    app["dependencies"] = [dependency for dependency in app["dependencies"] if "target" not in dependency]
    del app["entitlements"]
    app["info"]["path"] = INFO_PLIST_PATH
    app["settings"]["base"].update(
        {
            "PRODUCT_BUNDLE_IDENTIFIER": bundle_identifier(profile),
            "CODE_SIGN_STYLE": "Manual",
            "DEVELOPMENT_TEAM": profile["TeamIdentifier"][0],
            "CODE_SIGN_IDENTITY[sdk=appletvos*]": identity,
            "PROVISIONING_PROFILE_SPECIFIER[sdk=appletvos*]": profile["Name"],
        }
    )
    if build_number:
        spec["settings"]["base"]["CURRENT_PROJECT_VERSION"] = build_number
    spec["schemes"] = {
        PROJECT_NAME: {
            "build": {"targets": {APP_TARGET: "all"}},
            "run": {"config": "Release", "executable": APP_TARGET},
        }
    }
    return spec


def main():
    parser = argparse.ArgumentParser(description="Write the XcodeGen spec for a signed device build of the tvOS app.")
    parser.add_argument("--spec", required=True, help="tv/project.yml")
    parser.add_argument("--profile", required=True, help="development .mobileprovision for the Apple TV")
    parser.add_argument("--output", help="where to write the device spec")
    parser.add_argument("--identity", help="signing certificate SHA-1; defaults to the profile's only certificate")
    parser.add_argument("--build-number", help="CURRENT_PROJECT_VERSION override")
    parser.add_argument("--summary", action="store_true", help="print the profile facts as JSON instead of writing")
    args = parser.parse_args()

    profile = read_profile(args.profile)
    hashes = certificate_hashes(profile)
    identity = args.identity or hashes[0]
    if identity not in hashes:
        sys.exit(f"identity {identity} is not one of the profile's certificates: {', '.join(hashes)}")
    if args.summary:
        json.dump(
            {
                "name": profile["Name"],
                "uuid": profile["UUID"],
                "bundleId": bundle_identifier(profile),
                "identity": identity,
                "expires": profile["ExpirationDate"].isoformat(),
                "udids": profile.get("ProvisionedDevices", []),
            },
            sys.stdout,
        )
        return
    if not args.output:
        parser.error("--output is required unless --summary is given")
    with open(args.spec) as handle:
        spec = device_spec(handle.read(), profile, identity, args.build_number)
    with open(args.output, "w") as handle:
        yaml.safe_dump(spec, handle, sort_keys=False)


if __name__ == "__main__":
    main()
