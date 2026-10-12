#!/usr/bin/env python3
"""Attaches the review screenshot and review notes to Crucible Pro's two products and reports their state.

The products themselves are created as docs/asc-products.md describes. Each needs a screenshot of the paywall (Apple wants to see
where the purchase is offered) and a note for the reviewer; until then both stay MISSING_METADATA. Re-runnable: an existing
screenshot is left alone unless --replace is given.

Usage: python3 scripts/asc-products.py [--replace] PAYWALL_SCREENSHOT.png
"""
import subprocess
import sys

sys.path.insert(0, __import__("os").path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

APP = "6822066419"
LIFETIME = "6822070507"
YEARLY = "6822070396"
REVIEW_NOTE = (
    "Crucible Pro is offered on the paywall: iPhone, start a second download or open You > Statistics > Month; "
    "Apple TV, You > Statistics > Month. Settings > Crucible Pro opens it too. Sign in with the demo Plex account in the app review notes."
)


def run(*args):
    result = subprocess.run(["asc", *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"! asc {' '.join(args[:4])}: {result.stderr.strip()[:200] or result.stdout.strip()[:200]}")
    return result


def attach_lifetime(screenshot, replace):
    existing = asc.get(f"/v2/inAppPurchases/{LIFETIME}/appStoreReviewScreenshot").get("data")
    if existing and replace:
        run("iap", "review-screenshots", "delete", "--screenshot-id", existing["id"], "--confirm")
        existing = None
    if not existing:
        run("iap", "review-screenshots", "create", "--iap-id", LIFETIME, "--file", screenshot)
        print("lifetime: review screenshot uploaded")
    asc.patch(f"/v2/inAppPurchases/{LIFETIME}", {"data": {"type": "inAppPurchases", "id": LIFETIME,
        "attributes": {"reviewNote": REVIEW_NOTE}}})
    print("lifetime: review note set")


def attach_yearly(screenshot, replace):
    existing = asc.get(f"/v1/subscriptions/{YEARLY}/appStoreReviewScreenshot").get("data")
    if existing and replace:
        asc.req("DELETE", f"/v1/subscriptionAppStoreReviewScreenshots/{existing['id']}")
        existing = None
    if not existing:
        run("subscriptions", "review", "screenshots", "create", "--subscription-id", YEARLY, "--file", screenshot)
        print("yearly: review screenshot uploaded")
    asc.patch(f"/v1/subscriptions/{YEARLY}", {"data": {"type": "subscriptions", "id": YEARLY,
        "attributes": {"reviewNote": REVIEW_NOTE}}})
    print("yearly: review note set")


def report():
    for label, path in (("lifetime", f"/v2/inAppPurchases/{LIFETIME}"), ("yearly", f"/v1/subscriptions/{YEARLY}")):
        attributes = asc.get(path)["data"]["attributes"]
        print(f"{label}: {attributes.get('state')}")


def main():
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    replace = "--replace" in sys.argv
    if len(arguments) != 1:
        sys.exit(__doc__)
    attach_lifetime(arguments[0], replace)
    attach_yearly(arguments[0], replace)
    report()


if __name__ == "__main__":
    main()
