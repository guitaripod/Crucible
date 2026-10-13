#!/usr/bin/env python3
"""Idempotent App Store Connect listing for Crucible for Plex, iPhone and Apple TV on one app record.

Reads docs/asc-metadata.json and pushes the decided listing: categories, name, subtitle and privacy URL
(appInfoLocalization), description, keywords, promotional text and URLs for both platform versions, copyright,
release type, review details with the demo-mode notes, a free price, China-mainland availability off and an
all-NONE age rating. Re-runnable.

In-app purchases are scripts/asc-products.py; screenshots are scripts/asc-screenshots.py.

Usage: python3 scripts/asc-setup.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(ROOT, "docs/asc-metadata.json")))
APP_ID = spec["appId"]
VERSIONS = spec["versions"]
EDITABLE = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")


def first(path, **params):
    return asc.get(path, **params).get("data", [])


def push_app_info():
    info = first(f"/v1/apps/{APP_ID}/appInfos")[0]
    asc.patch(f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"],
        "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": spec["primaryCategory"]}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": spec["secondaryCategory"]}}}}})
    print(f"categories -> {spec['primaryCategory']} / {spec['secondaryCategory']}")
    ilocs = first(f"/v1/appInfos/{info['id']}/appInfoLocalizations")
    iloc = next(l["id"] for l in ilocs if l["attributes"].get("locale") == "en-US")
    asc.patch(f"/v1/appInfoLocalizations/{iloc}", {"data": {"type": "appInfoLocalizations",
        "id": iloc, "attributes": {
            "name": spec["name"], "subtitle": spec["subtitle"],
            "privacyPolicyUrl": spec["privacyPolicyUrl"],
            "privacyPolicyText": open(os.path.join(ROOT, "docs/privacy-policy.txt")).read()}}})
    print(f"name, subtitle, privacy URL and text set ({iloc})")


def push_version(platform, version_id):
    version = asc.get(f"/v1/appStoreVersions/{version_id}")["data"]
    state = version["attributes"].get("appStoreState")
    if state not in EDITABLE:
        print(f"{platform}: version is {state}, not editable; skipped")
        return
    asc.patch(f"/v1/appStoreVersions/{version_id}", {"data": {"type": "appStoreVersions",
        "id": version_id, "attributes": {
            "releaseType": spec.get("releaseType", "AFTER_APPROVAL"),
            "copyright": spec["copyright"]}}})
    vlocs = first(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    vloc = next(l["id"] for l in vlocs if l["attributes"].get("locale") == "en-US")
    attributes = {
        "description": spec["description"], "keywords": spec["keywords"],
        "promotionalText": spec["promotionalText"],
        "supportUrl": spec["supportUrl"], "marketingUrl": spec["marketingUrl"]}
    asc.patch(f"/v1/appStoreVersionLocalizations/{vloc}", {"data": {
        "type": "appStoreVersionLocalizations", "id": vloc, "attributes": attributes}})
    print(f"{platform}: localization set, release={spec.get('releaseType', 'AFTER_APPROVAL')}")
    push_review_details(platform, version_id)


def contact_phone():
    """contactPhone is required by the API; reuse the one already on file for another of the team's apps."""
    for app in ["6779927672", "6785542220", "6787688416", "6791660932"]:
        for version in asc.get(f"/v1/apps/{app}/appStoreVersions", limit=3).get("data", []):
            detail = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
            if detail and detail["attributes"].get("contactPhone"):
                return detail["attributes"]["contactPhone"]
    return None


def push_review_details(platform, version_id):
    existing = asc.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail").get("data")
    attributes = {
        "contactFirstName": spec["contactFirstName"],
        "contactLastName": spec["contactLastName"],
        "contactEmail": spec["contactEmail"],
        "demoAccountRequired": False,
        "notes": spec["reviewNotes"],
    }
    if existing:
        asc.patch(f"/v1/appStoreReviewDetails/{existing['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": existing["id"], "attributes": attributes}})
        print(f"{platform}: review details updated")
        return
    phone = contact_phone()
    if not phone:
        print(f"! {platform}: no contact phone found on any sibling app; set review details in the web UI")
        return
    attributes["contactPhone"] = phone
    asc.post("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails",
        "attributes": attributes, "relationships": {"appStoreVersion": {
            "data": {"type": "appStoreVersions", "id": version_id}}}}})
    print(f"{platform}: review details created")


def push_free_price():
    points = asc.get(f"/v1/apps/{APP_ID}/appPricePoints",
                     **{"filter[territory]": "USA", "fields[appPricePoints]": "customerPrice",
                        "limit": "200"}).get("data", [])
    free = next(p for p in points if p["attributes"].get("customerPrice") == "0.0")
    asc.post("/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules",
        "relationships": {
            "app": {"data": {"type": "apps", "id": APP_ID}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${p}"}]}},
        }, "included": [{"type": "appPrices", "id": "${p}",
            "attributes": {"startDate": None},
            "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    print("price -> Free (equalizes worldwide)")


def push_availability_minus_china():
    territories = []
    page = asc.get("/v1/territories?limit=200")
    territories += [t["id"] for t in page.get("data", [])]
    nxt = page.get("links", {}).get("next")
    while nxt:
        page = asc.req("GET", "", raw_url=nxt)
        territories += [t["id"] for t in page.get("data", [])]
        nxt = page.get("links", {}).get("next")
    included = [{"type": "territoryAvailabilities", "id": f"${{t{i}}}",
                 "attributes": {"available": t != "CHN"},
                 "relationships": {"territory": {"data": {"type": "territories", "id": t}}}}
                for i, t in enumerate(territories)]
    asc.post("/v2/appAvailabilities", {"data": {"type": "appAvailabilities",
        "attributes": {"availableInNewTerritories": True},
        "relationships": {
            "app": {"data": {"type": "apps", "id": APP_ID}},
            "territoryAvailabilities": {"data": [
                {"type": "territoryAvailabilities", "id": f"${{t{i}}}"}
                for i in range(len(territories))]}},
        }, "included": included})
    print(f"availability -> {len(territories) - 1} territories (China mainland off)")


def push_age_rating():
    """The 2025 questionnaire lives on the appInfo, not the appStoreVersion."""
    info = first(f"/v1/apps/{APP_ID}/appInfos")[0]
    declaration = asc.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data")
    if not declaration:
        print("! no ageRatingDeclaration resource; set it in the web UI")
        return
    wanted = {
        "advertising": False, "alcoholTobaccoOrDrugUseOrReferences": "NONE", "contests": "NONE",
        "gambling": False, "gamblingSimulated": "NONE", "gunsOrOtherWeapons": "NONE",
        "healthOrWellnessTopics": False, "lootBox": False, "medicalOrTreatmentInformation": "NONE",
        "messagingAndChat": False, "parentalControls": False, "profanityOrCrudeHumor": "NONE",
        "ageAssurance": False, "sexualContentGraphicAndNudity": "NONE", "sexualContentOrNudity": "NONE",
        "socialMedia": False, "socialMediaAgeRestricted": False, "horrorOrFearThemes": "NONE",
        "matureOrSuggestiveThemes": "NONE", "unrestrictedWebAccess": False, "userGeneratedContent": False,
        "violenceCartoonOrFantasy": "NONE", "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        "violenceRealistic": "NONE",
    }
    present = declaration.get("attributes", {})
    attributes = {k: v for k, v in wanted.items() if k in present}
    asc.patch(f"/v1/ageRatingDeclarations/{declaration['id']}", {"data": {
        "type": "ageRatingDeclarations", "id": declaration["id"], "attributes": attributes}})
    print(f"age rating set ({len(attributes)} fields)")


def main():
    push_app_info()
    for platform, version_id in VERSIONS.items():
        push_version(platform, version_id)
    for step in (push_free_price, push_availability_minus_china, push_age_rating):
        try:
            step()
        except Exception as error:
            print(f"! {step.__name__}: {str(error)[:200]}")
    print("DONE")


if __name__ == "__main__":
    main()
