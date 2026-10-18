#!/usr/bin/env python3
"""Check catalogs against actual Xcode extraction and literal runtime lookups.

Run after building: python3 -I scripts/check-localizations.py --derived-data <path>
Dynamic display values are additionally covered by the native identity/resource tests.
"""
import argparse
import json
from pathlib import Path
import re
import sys


FORMAT = re.compile(
    r"%(?:([0-9]+)\$)?[-+#0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?"
    r"((?:ll|l|hh|h|z|t|j)?[diuoxXfFeEgGaAcCsSp@])"
)
LOOKUP = re.compile(r'(?:AppLocalization|CameraRawLocalization)\.(?:string|format)\(\s*("(?:[^"\\]|\\.)*")(?=\s*[,\)])')


def arguments(text):
    # A percent followed by prose whitespace ("120% of") isn't a format argument.
    return sorted((match[1] or str(index + 1), match[2])
                  for index, match in enumerate(FORMAT.finditer(text.replace("%%", ""))))


def check(root, derived_data):
    errors = []
    total_keys = 0
    total_extracted = 0
    for target in ["Compositor", "CameraRawPlugin"]:
        catalog_path = root / target / "Localizable.xcstrings"
        catalog = json.loads(catalog_path.read_text())
        if catalog.get("sourceLanguage") != "en":
            errors.append(f"{target}: source language is not en")
        strings = catalog["strings"]
        total_keys += len(strings)
        for key, entry in strings.items():
            for language in ["en", "zh-Hans"]:
                unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
                value = unit.get("value")
                if not isinstance(value, str) or unit.get("state") != "translated":
                    errors.append(f"{target}: missing {language} translation: {key!r}")
                elif arguments(key) != arguments(value):
                    errors.append(f"{target}: changed {language} format arguments: {key!r}")

        def require(key, origin):
            if key and key not in strings:
                errors.append(f"{target}: missing key {key!r} ({origin})")

        for source in (root / target).rglob("*.swift"):
            for match in LOOKUP.finditer(source.read_text()):
                try:
                    key = json.loads(match[1])
                except json.JSONDecodeError:
                    errors.append(f"{source.name}: runtime key isn't a plain literal: {match[1]}")
                    continue
                require(key, source.name)

        extraction_root = derived_data / "Build/Intermediates.noindex/Compositor.build/Debug" / f"{target}.build/Objects-normal"
        extracted = list(extraction_root.rglob("*.stringsdata"))
        if not extracted:
            errors.append(f"{target}: no compiler extraction found; build the Debug scheme first")
        for path in extracted:
            data = json.loads(path.read_text())
            for row in data.get("tables", {}).get("Localizable", []):
                total_extracted += 1
                require(row["key"], Path(data["source"]).name)

        if target == "Compositor":
            source = (root / "Compositor/Document/CameraRawPluginEditing.swift").read_text()
            for title, group in re.findall(r'\badd\("[^"]+", "([^"]+)", "([^"]+)"', source):
                require(title, "plugin control title")
                require(group, "plugin control group")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"PASS: {total_keys} catalog keys, {total_extracted} compiler-extracted occurrences, "
          "literal runtime lookups and plugin metadata; English/Chinese formats match")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    return check(root, args.derived_data)


if __name__ == "__main__":
    sys.exit(main())
