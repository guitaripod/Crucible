#!/usr/bin/env python3
"""Turns an `xcresulttool export attachments` directory into tv/out/ui/<Class.test>/<attachment-name>.<ext>.

Usage: arrange_attachments.py <raw-export-dir> <ui-out-dir>
"""
import json
import os
import re
import shutil
import sys

SUFFIX = re.compile(r"^(?P<name>.*)_\d+_[0-9A-Fa-f-]{36}(?P<ext>\.[A-Za-z0-9]+)$")


def readable_name(entry):
    suggested = entry["suggestedHumanReadableName"]
    match = SUFFIX.match(suggested)
    return match["name"] + match["ext"] if match else suggested


def test_directory(identifier):
    parts = identifier.removesuffix("()").split("/")
    return ".".join(parts[-2:]) if len(parts) > 1 else parts[0]


ISSUE_ATTACHMENT = "Complete Issue Description"


def main(raw, out):
    with open(os.path.join(raw, "manifest.json")) as f:
        manifest = json.load(f)
    for child in os.listdir(out):
        path = os.path.join(out, child)
        if path != raw and os.path.isdir(path):
            shutil.rmtree(path)
    exported = []
    issues = []
    for test in manifest:
        directory = os.path.join(out, test_directory(test["testIdentifier"]))
        os.makedirs(directory, exist_ok=True)
        for attachment in sorted(test["attachments"], key=lambda a: a.get("timestamp", 0)):
            target = os.path.join(directory, readable_name(attachment))
            if os.path.basename(target).startswith(ISSUE_ATTACHMENT):
                issues.append(test_directory(test["testIdentifier"]))
            shutil.move(os.path.join(raw, attachment["exportedFileName"]), target)
            exported.append(target)
    shutil.rmtree(raw)
    print(f"exported {len(exported)} attachments:")
    for path in exported:
        print(path)
    if issues:
        print("runtime issues reported during: " + ", ".join(sorted(set(issues))), file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
