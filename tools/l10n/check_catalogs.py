#!/usr/bin/env python3
"""Checks every .xcstrings catalog in the repo for translation coverage and consistency.

Usage:
    python3 -I tools/l10n/check_catalogs.py [--locales de,es,...] [--summary] [path ...]

A catalog is complete when every key that is not marked shouldTranslate=false has a non-empty value in every
required locale, the value uses the same format placeholders as the source, plural keys carry the plural
categories the locale needs, and no value contains an em dash. Exit status 1 when anything is missing.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOCALES = ["de", "es", "fr", "it", "ja", "ko", "pl", "pt-BR", "zh-Hans", "zh-Hant"]
PLURAL_CATEGORIES = {
    "de": {"one", "other"}, "es": {"one", "many", "other"}, "fr": {"one", "many", "other"}, "it": {"one", "many", "other"},
    "ja": {"other"}, "ko": {"other"}, "pl": {"one", "few", "many", "other"}, "pt-BR": {"one", "many", "other"},
    "zh-Hans": {"other"}, "zh-Hant": {"other"},
}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|u|@|f|\.\d+f|s|c)|\{[A-Za-z_][A-Za-z0-9_]*\}")
SKIP_DIRS = {".build", "node_modules", "DerivedData", "Legacy", ".git", "dd", "build"}


def catalogs(paths):
    if paths:
        for path in paths:
            yield Path(path)
        return
    for path in sorted(ROOT.rglob("*.xcstrings")):
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
            continue
        yield path


def values(localization):
    """Every string value in a localization, whether plain, plural or device varied."""
    if "stringUnit" in localization:
        yield "other", localization["stringUnit"].get("value", "")
    for kind in ("plural", "device"):
        for category, inner in localization.get("variations", {}).get(kind, {}).items():
            for _, text in values(inner):
                yield category, text


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def check(path, locales, problems, stats):
    data = json.loads(path.read_text(encoding="utf-8"))
    source_language = data.get("sourceLanguage", "en")
    strings = data.get("strings", {})
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        stats["keys"] += 1
        localizations = entry.get("localizations", {})
        source = localizations.get(source_language)
        source_values = list(values(source)) if source else [(None, key)]
        source_text = source_values[0][1] if source_values else key
        source_placeholders = placeholders(source_text)
        is_plural = bool(source and source.get("variations", {}).get("plural"))
        for locale in locales:
            localization = localizations.get(locale)
            if not localization:
                problems.append(f"{path.relative_to(ROOT)}: {key!r} missing {locale}")
                stats["missing"] += 1
                continue
            texts = list(values(localization))
            if not texts or any(not text.strip() for _, text in texts):
                problems.append(f"{path.relative_to(ROOT)}: {key!r} empty in {locale}")
                stats["missing"] += 1
                continue
            for _, text in texts:
                if "—" in text:
                    problems.append(f"{path.relative_to(ROOT)}: {key!r} has an em dash in {locale}")
                if placeholders(text) != source_placeholders and not is_plural:
                    problems.append(f"{path.relative_to(ROOT)}: {key!r} placeholders differ in {locale}: {placeholders(text)} vs {source_placeholders}")
            if is_plural:
                have = {category for category, _ in texts}
                need = PLURAL_CATEGORIES.get(locale, {"other"})
                if not need.issubset(have):
                    problems.append(f"{path.relative_to(ROOT)}: {key!r} plural categories in {locale} are {sorted(have)}, need {sorted(need)}")


def main():
    args = sys.argv[1:]
    locales = DEFAULT_LOCALES
    summary = False
    paths = []
    i = 0
    while i < len(args):
        if args[i] == "--locales":
            locales = args[i + 1].split(",")
            i += 2
        elif args[i] == "--summary":
            summary = True
            i += 1
        else:
            paths.append(args[i])
            i += 1
    problems, stats = [], {"keys": 0, "missing": 0, "files": 0}
    for path in catalogs(paths):
        stats["files"] += 1
        before = len(problems)
        check(path, locales, problems, stats)
        print(f"{path.relative_to(ROOT)}: {len(problems) - before} problems")
    if not summary:
        for line in problems[:200]:
            print("  " + line)
        if len(problems) > 200:
            print(f"  ... {len(problems) - 200} more")
    print(f"{stats['files']} catalogs, {stats['keys']} keys, {len(locales)} locales, {len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
