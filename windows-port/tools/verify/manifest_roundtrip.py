"""Checks that the Rust reader reproduces a Python-written manifest field for field.

Run:  python manifest_roundtrip.py [path-to-compc]
Exits 1 when a shared field differs or a field the original set is dropped.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLI = os.path.join(HERE, "..", "..", "target-lead", "debug", "compc.exe")

# Fields the Rust writer adds on purpose: a missing maskLinked means "linked", so writing it is
# equivalent, and the transform is always written in full.
IGNORED_ADDITIONS = {"maskLinked"}


def flatten(value, prefix=""):
    """Turns nested JSON into a flat dict so a diff names the exact field."""
    flat = {}
    if isinstance(value, dict):
        for key, item in value.items():
            flat.update(flatten(item, f"{prefix}.{key}" if prefix else key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            flat.update(flatten(item, f"{prefix}[{index}]"))
    else:
        flat[prefix] = value
    return flat


def compare_manifest(original, produced):
    a, b = flatten(original), flatten(produced)
    problems = []
    for key, value in a.items():
        if key in IGNORED_ADDITIONS:
            continue
        if key not in b:
            problems.append(f"missing {key} (was {value!r})")
        elif b[key] != value:
            problems.append(f"{key}: {value!r} -> {b[key]!r}")
    for key in b:
        if key in a:
            continue
        leaf = key.split(".")[-1].split("[")[0]
        if leaf in IGNORED_ADDITIONS:
            continue
        problems.append(f"added {key} = {b[key]!r}")
    return problems


def main(argv):
    cli = os.path.abspath(argv[1] if len(argv) > 1 else DEFAULT_CLI)
    if not os.path.exists(cli):
        print(f"CLI not found: {cli}")
        return 2
    fixtures_dir = os.path.join(HERE, "fixtures")
    packages = sorted(
        os.path.join(fixtures_dir, name)
        for name in os.listdir(fixtures_dir)
        if name.endswith(".comp")
    )
    failed = 0
    checked = 0
    for package in packages:
        with open(os.path.join(package, "manifest.json"), "r", encoding="utf-8") as handle:
            original = json.load(handle)
        process = subprocess.run([cli, "info", package, "--json"], capture_output=True, text=True)
        if process.returncode != 0:
            print(f"FAIL {os.path.basename(package)}: compc info failed: {process.stderr.strip()}")
            failed += 1
            continue
        produced = json.loads(process.stdout)
        problems = compare_manifest(original, produced)
        checked += 1
        if problems:
            failed += 1
            print(f"FAIL {os.path.basename(package)}")
            for problem in problems[:8]:
                print(f"     {problem}")
        else:
            print(f"PASS {os.path.basename(package)}")
    print(f"\n{checked - failed}/{checked} manifests reproduced field for field")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
