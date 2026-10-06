"""Checks that the checks fail when they are supposed to.

Each check is run twice: once against the real CLI, once against a sabotaged copy that forwards every
command and then damages the result. A check that passes in both cases is not checking anything.

Usage: python verify_checks.py [--quick]
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# Each entry: the check, and how it wants to be told which CLI to use. The pixel acceptance takes it
# positionally; the PowerShell checks take -Cli. acceptance.py is the one that matters most -- it is the
# oracle comparison the whole project's pixel claims rest on -- so it is in the default set.
CANDIDATES = [
    ("acceptance.py", "positional"),
    ("check_gpu.ps1", "-Cli"),
    ("check_psd.ps1", "-Cli"),
    ("check_versions.ps1", "-Cli"),
    ("check_regions.ps1", "-Cli"),
]
QUICK = ["acceptance.py", "check_versions.ps1"]


def run_check(script, cli, style):
    if script.endswith(".py"):
        command = [sys.executable, os.path.join(HERE, script)]
    else:
        command = ["pwsh", "-NoProfile", "-File", os.path.join(HERE, script)]
    if cli:
        command += [cli] if style == "positional" else [style, cli]
    result = subprocess.run(command, capture_output=True, text=True, cwd=HERE)
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--cli", default=None, help="the real CLI; defaults to the debug build")
    args = parser.parse_args(argv)

    root = os.path.dirname(os.path.dirname(HERE))
    cli = args.cli or os.path.join(root, "target-lead", "debug", "compc.exe")
    if not os.path.isfile(cli):
        print(f"compc not found: {cli}")
        return 2

    python = sys.executable
    wrapper = os.path.join(tempfile.mkdtemp(prefix="compsabotage-"), "compc.cmd")
    with open(wrapper, "w", encoding="utf-8") as handle:
        handle.write(f'@echo off\n"{python}" "{os.path.join(HERE, "sabotage.py")}" "{cli}" %*\n')

    selected = QUICK if args.quick else [name for name, _ in CANDIDATES]
    failures = 0
    for script in selected:
        style = dict(CANDIDATES).get(script, "-Cli")
        healthy, healthy_output = run_check(script, cli, style)
        if healthy != 0:
            print(f"FAIL {script}: it does not pass against the real tool, so it cannot be trusted")
            print("      " + healthy_output.strip().splitlines()[-1][:140] if healthy_output.strip() else "")
            failures += 1
            continue
        sabotaged, _ = run_check(script, wrapper, style)
        if sabotaged == 0:
            print(f"FAIL {script}: it still passed against a sabotaged tool - it is not checking anything")
            failures += 1
        else:
            print(f"ok   {script}: passes on the real tool and fails on the sabotaged one")

    print(f"{len(selected)} checks exercised, {failures} not doing their job")
    if failures:
        print("FAIL")
        return 1
    print("PASS every check noticed the sabotage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
