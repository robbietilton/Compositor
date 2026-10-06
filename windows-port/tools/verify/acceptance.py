"""Runs every fixture through the CLI and compares the result with the reference.

Run:  python acceptance.py [path-to-compc] [--tolerance N]
Default CLI: ../../target-lead/debug/compc.exe
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

import compare as compare_module

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLI = os.path.join(HERE, "..", "..", "target-lead", "debug", "compc.exe")


def main(argv):
    cli = DEFAULT_CLI
    tolerance = 1
    args = [a for a in argv[1:]]
    if args and not args[0].startswith("-"):
        cli = args.pop(0)
    if "--tolerance" in args:
        tolerance = int(args[args.index("--tolerance") + 1])
    cli = os.path.abspath(cli)
    if not os.path.exists(cli):
        print(f"CLI not found: {cli}")
        return 2

    with open(os.path.join(HERE, "fixtures", "index.json"), "r", encoding="utf-8") as handle:
        index = json.load(handle)["fixtures"]

    failures = []
    passed = 0
    with tempfile.TemporaryDirectory() as work:
        for fixture in index:
            package = os.path.join(HERE, fixture["package"])
            expected = os.path.join(HERE, fixture["expected"])
            actual = os.path.join(work, fixture["name"] + ".png")
            process = subprocess.run(
                [cli, "render", package, "-o", actual],
                capture_output=True, text=True,
            )
            if process.returncode != 0:
                failures.append((fixture["name"], f"compc render failed: {process.stderr.strip()[:200]}"))
                continue
            result = compare_module.compare(expected, actual, tolerance)
            if result.get("ok"):
                passed += 1
                print(f"PASS {fixture['name']:<28} worst={result['worst']} mean={result['mean']:.4f}")
            else:
                failures.append((fixture["name"], json.dumps(result)))
                print(f"FAIL {fixture['name']:<28} {json.dumps(result)}")

    print(f"\n{passed}/{len(index)} fixtures matched within {tolerance} level(s)")
    if failures:
        print("\nfailures:")
        for name, reason in failures:
            print(f"  {name}: {reason}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
