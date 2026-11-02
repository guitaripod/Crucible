#!/usr/bin/env python3
"""Moves translations in and out of the .xcstrings catalogs as plain JSON, so a translator never edits a catalog.

Usage:
    python3 -I tools/l10n/translate_io.py export --locale de [--out FILE] [catalog ...]
    python3 -I tools/l10n/translate_io.py validate EXPORT_FILE TRANSLATION_FILE
    python3 -I tools/l10n/translate_io.py apply FILE [--overwrite]

export lists every key that still lacks a complete translation in the locale: the English text, the translator
comment, and for a plural key the English text of each plural category. Without catalog arguments every catalog in
the repo is read.

validate compares a translation file with the export it answers, without touching any catalog. It fails when a key
is missing or extra, a string is empty or has an em dash, the format placeholders differ from the English, or a
plural key does not carry exactly the categories the locale needs. It only warns about a string that is longer than
a button or chip can take, or identical to the English, so the translator can look at those.

apply takes a file of the form {"locale": "de", "catalogs": {"<catalog path>": {"<key>": <translation>}}} where a
translation is a string, or for a plural key an object with one string per plural category the locale needs. It
writes the catalogs in the layout Xcode uses and leaves an existing translation alone unless --overwrite is given.
Run tools/l10n/check_catalogs.py afterwards: it checks placeholders, plural categories and the no em dash rule.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLURAL_CATEGORIES = {
    "de": ["one", "other"], "es": ["one", "many", "other"], "fr": ["one", "many", "other"],
    "it": ["one", "many", "other"], "ja": ["other"], "ko": ["other"], "pl": ["one", "few", "many", "other"],
    "pt-BR": ["one", "many", "other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
}
SKIP_DIRS = {".build", "node_modules", "DerivedData", "Legacy", ".git", "dd", "build"}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|u|@|f|\.\d+f|s|c)|\{[A-Za-z_][A-Za-z0-9_]*\}")
NO_LENGTH_WARNING = {"ja", "ko", "zh-Hans", "zh-Hant"}


def catalog_paths(arguments):
    """The catalogs to read: the ones named, or every catalog of the repo outside the skipped folders."""
    if arguments:
        return [Path(argument).resolve() for argument in arguments]
    return [
        path for path in sorted(ROOT.rglob("*.xcstrings"))
        if not any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts)
    ]


def relative(path):
    return str(path.resolve().relative_to(ROOT))


def read_catalog(path):
    """The parsed catalog and whether the file ends with a newline, so a write keeps the file layout."""
    text = path.read_text(encoding="utf-8")
    return json.loads(text), text.endswith("\n")


def write_catalog(path, data, ends_with_newline):
    text = json.dumps(data, indent=2, ensure_ascii=False, separators=(",", " : "))
    path.write_text(text + ("\n" if ends_with_newline else ""), encoding="utf-8")


def plural_source(entry):
    """The English text per plural category of a plural key, or None for a plain key."""
    english = entry.get("localizations", {}).get("en", {})
    plural = english.get("variations", {}).get("plural")
    if plural is None:
        return None
    return {category: inner["stringUnit"]["value"] for category, inner in plural.items()}


def plain_source(entry):
    english = entry.get("localizations", {}).get("en", {})
    return english.get("stringUnit", {}).get("value")


def extra_categories(source):
    """The explicit zero category of a plural key whose English text has one, which every locale then carries too."""
    return ["zero"] if source is not None and "zero" in source else []


def is_complete(entry, locale):
    """Whether the locale has a non-empty value for the key, and for a plural key every category it needs."""
    localization = entry.get("localizations", {}).get(locale)
    if localization is None:
        return False
    source = plural_source(entry)
    if source is not None:
        plural = localization.get("variations", {}).get("plural", {})
        needed = PLURAL_CATEGORIES[locale] + extra_categories(source)
        return all(plural.get(category, {}).get("stringUnit", {}).get("value", "").strip() for category in needed)
    if has_plural_forms(localization):
        return True
    return bool(localization.get("stringUnit", {}).get("value", "").strip())


def has_plural_forms(localization):
    """Whether a locale already carries its own plural forms for a key whose English is plain, which a plain
    translation must never replace."""
    plural = localization.get("variations", {}).get("plural", {})
    return bool(plural) and all(inner.get("stringUnit", {}).get("value", "").strip() for inner in plural.values())


def export(locale, arguments):
    catalogs = {}
    for path in catalog_paths(arguments):
        data, _ = read_catalog(path)
        missing = {}
        for key, entry in data.get("strings", {}).items():
            if entry.get("shouldTranslate") is False or is_complete(entry, locale):
                continue
            plural = plural_source(entry)
            missing[key] = {"comment": entry.get("comment", ""), "source": plural if plural is not None else (plain_source(entry) or key)}
        if missing:
            catalogs[relative(path)] = missing
    return {"locale": locale, "pluralCategories": PLURAL_CATEGORIES[locale], "catalogs": catalogs}


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def text_problems(text, source_text, where, plural):
    """Hard errors for one translated string: empty, em dash, or placeholders that differ from the English."""
    if not isinstance(text, str) or not text.strip():
        return [f"{where}: empty or not a string"]
    problems = []
    if "\u2014" in text:
        problems.append(f"{where}: has an em dash")
    have, want = placeholders(text), placeholders(source_text)
    if plural:
        extra = [item for item in have if item not in want]
        if extra:
            problems.append(f"{where}: placeholders {extra} are not in the English {want}")
    elif have != want:
        problems.append(f"{where}: placeholders {have} differ from the English {want}")
    return problems


def text_warnings(text, source_text, where, locale):
    """Soft findings for one translated string: much longer than the English, or unchanged from it."""
    warnings = []
    letters = sum(character.isalpha() for character in source_text)
    if locale not in NO_LENGTH_WARNING:
        limit = 2 * len(source_text) + 8 if len(source_text) <= 30 else 1.8 * len(source_text) + 20
        if len(text) > limit:
            warnings.append(f"{where}: {len(text)} characters against {len(source_text)} in the English, shorten it")
    if letters >= 4 and text.strip().lower() == source_text.strip().lower():
        warnings.append(f"{where}: identical to the English")
    return warnings


def validate(export_document, translation_document):
    """The (problems, warnings) of a translation file measured against the export it answers."""
    locale = export_document["locale"]
    problems, warnings = [], []
    if translation_document.get("locale") != locale:
        problems.append(f"the translation is for {translation_document.get('locale')!r}, the export for {locale!r}")
    needed = PLURAL_CATEGORIES[locale]
    given_catalogs = translation_document.get("catalogs", {})
    for catalog, keys in export_document["catalogs"].items():
        given = given_catalogs.get(catalog, {})
        for key in keys.keys() - given.keys():
            problems.append(f"{catalog}: {key!r} is missing")
        for key in given.keys() - keys.keys():
            problems.append(f"{catalog}: {key!r} was not asked for")
        for key, info in keys.items():
            if key not in given:
                continue
            where, source, text = f"{catalog}: {key!r}", info["source"], given[key]
            if isinstance(source, dict):
                allowed = set(needed) | set(extra_categories(source))
                if not isinstance(text, dict) or not set(needed) <= set(text) <= allowed:
                    problems.append(f"{where}: needs the plural categories {needed} and may add {sorted(allowed - set(needed))}")
                    continue
                for category, value in text.items():
                    problems.extend(text_problems(value, source["other"], f"{where} [{category}]", True))
                continue
            problems.extend(text_problems(text, source, where, False))
            if isinstance(text, str):
                warnings.extend(text_warnings(text, source, where, locale))
    for catalog in given_catalogs.keys() - export_document["catalogs"].keys():
        problems.append(f"{catalog}: was not asked for")
    return problems, warnings


def string_unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization_for(entry, locale, translation, problems, where):
    """The catalog localization for one translation, or None after recording why the translation was refused."""
    source = plural_source(entry)
    if source is not None:
        needed = PLURAL_CATEGORIES[locale]
        allowed = set(needed) | set(extra_categories(source))
        if not isinstance(translation, dict) or not set(needed) <= set(translation) <= allowed:
            problems.append(f"{where}: a plural key needs the categories {needed} and may add {sorted(allowed - set(needed))}")
            return None
        if not all(isinstance(text, str) and text.strip() for text in translation.values()):
            problems.append(f"{where}: every plural category needs a non-empty string")
            return None
        return {"variations": {"plural": {category: string_unit(text) for category, text in translation.items()}}}
    if not isinstance(translation, str) or not translation.strip():
        problems.append(f"{where}: a plain key needs a non-empty string")
        return None
    return string_unit(translation)


def apply(document, overwrite):
    locale = document["locale"]
    if locale not in PLURAL_CATEGORIES:
        sys.exit(f"unknown locale {locale}")
    problems = []
    applied = 0
    for catalog, translations in document["catalogs"].items():
        path = ROOT / catalog
        data, ends_with_newline = read_catalog(path)
        strings = data["strings"]
        for key, translation in translations.items():
            where = f"{catalog}: {key!r}"
            entry = strings.get(key)
            if entry is None or entry.get("shouldTranslate") is False:
                problems.append(f"{where}: no such translatable key")
                continue
            if is_complete(entry, locale) and not overwrite:
                continue
            localization = localization_for(entry, locale, translation, problems, where)
            if localization is None:
                continue
            localizations = entry.setdefault("localizations", {})
            localizations[locale] = localization
            entry["localizations"] = dict(sorted(localizations.items()))
            applied += 1
        write_catalog(path, data, ends_with_newline)
    for problem in problems:
        print(problem, file=sys.stderr)
    print(f"applied {applied} translations for {locale}, refused {len(problems)}")
    return 1 if problems else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    export_parser = commands.add_parser("export")
    export_parser.add_argument("--locale", required=True, choices=sorted(PLURAL_CATEGORIES))
    export_parser.add_argument("--out")
    export_parser.add_argument("catalogs", nargs="*")
    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument("export_file")
    validate_parser.add_argument("translation_file")
    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("file")
    apply_parser.add_argument("--overwrite", action="store_true")
    arguments = parser.parse_args()
    if arguments.command == "export":
        text = json.dumps(export(arguments.locale, arguments.catalogs), indent=2, ensure_ascii=False)
        if arguments.out:
            Path(arguments.out).write_text(text + "\n", encoding="utf-8")
        else:
            print(text)
        return 0
    if arguments.command == "validate":
        export_document = json.loads(Path(arguments.export_file).read_text(encoding="utf-8"))
        translation_document = json.loads(Path(arguments.translation_file).read_text(encoding="utf-8"))
        problems, warnings = validate(export_document, translation_document)
        for line in warnings:
            print("warning: " + line)
        for line in problems:
            print("problem: " + line)
        print(f"{len(problems)} problems, {len(warnings)} warnings")
        return 1 if problems else 0
    document = json.loads(Path(arguments.file).read_text(encoding="utf-8"))
    return apply(document, arguments.overwrite)


if __name__ == "__main__":
    sys.exit(main())
