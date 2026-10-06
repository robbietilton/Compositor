"""Feeds damaged packages to the tools and insists they fail cleanly.

A file format implementation meets two kinds of input: the ones a person made, and the ones a corrupt
disk, a half-finished download or a hostile author produced. The second kind must never panic, abort or
hang -- a clean error is fine, a crash is a bug, and a hang is worse than either because it takes the
editor down with it.

Mutations are applied to real fixtures, one at a time, so a failure names a single cause.

Usage:
  python fuzz_hostile.py --cli <compc> [--per-fixture 6] [--timeout 25] [--keep]
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
FAILURES = os.path.join(HERE, "fuzz-hostile-failures")

CRASH_CODES = {
    -1073741819: "access violation",
    -1073741571: "stack overflow",
    -1073740791: "stack buffer overrun",
    -1073740940: "heap corruption",
    3221225477: "access violation",
    3221225725: "stack overflow",
}


def first_manifest(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_manifest(path, manifest, raw=None):
    with open(path, "w", encoding="utf-8") as handle:
        if raw is not None:
            handle.write(raw)
        else:
            json.dump(manifest, handle, indent=2, sort_keys=True)


def mutation_truncate(package, rng):
    path = os.path.join(package, "manifest.json")
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    cut = rng.randint(1, max(1, len(text) - 1))
    write_manifest(path, None, raw=text[:cut])
    return f"manifest truncated at {cut} of {len(text)} bytes"


def mutation_wrong_type(package, rng):
    path = os.path.join(package, "manifest.json")
    manifest = first_manifest(path)
    if not manifest["layers"]:
        return None
    layer = rng.choice(manifest["layers"])
    field = rng.choice(["opacity", "blendMode", "isVisible", "name", "transform", "id"])
    replacement = rng.choice([None, "text", 12345, [1, 2, 3], {"a": 1}, True])
    layer[field] = replacement
    write_manifest(path, manifest)
    return f"layers[].{field} replaced with {type(replacement).__name__}"


def mutation_bad_uuid(package, rng):
    path = os.path.join(package, "manifest.json")
    manifest = first_manifest(path)
    layer = rng.choice(manifest["layers"])
    choice = rng.choice(["lowercase", "garbage", "no-dashes", "empty", "other-layer"])
    if choice == "lowercase":
        layer["id"] = layer["id"].lower()
    elif choice == "garbage":
        layer["id"] = "not-a-uuid"
    elif choice == "no-dashes":
        layer["id"] = layer["id"].replace("-", "")
    elif choice == "empty":
        layer["id"] = ""
    else:
        others = [entry["id"] for entry in manifest["layers"] if entry is not layer]
        if not others:
            return None
        layer["id"] = rng.choice(others)
    write_manifest(path, manifest)
    return f"layer id made {choice}"


def mutation_bad_path(package, rng):
    path = os.path.join(package, "manifest.json")
    manifest = first_manifest(path)
    candidates = [entry for entry in manifest["layers"] if entry.get("imageFile") or entry.get("maskFile")]
    if not candidates:
        return None
    layer = rng.choice(candidates)
    field = "imageFile" if layer.get("imageFile") else "maskFile"
    layer[field] = rng.choice([
        "../../evil.png", "..\\..\\evil.png", "C:\\Windows\\win.ini", "/etc/passwd",
        "images/../manifest.json", "", "nested/deeper/x.png", "x" * 300 + ".png",
    ])
    write_manifest(path, manifest)
    return f"{field} pointed outside the package"


def mutation_asset_damage(package, rng):
    images = os.path.join(package, "images")
    files = [name for name in os.listdir(images)] if os.path.isdir(images) else []
    if not files:
        return None
    target = os.path.join(images, rng.choice(files))
    choice = rng.choice(["empty", "garbage", "truncated", "huge-header"])
    if choice == "empty":
        open(target, "wb").close()
    elif choice == "garbage":
        with open(target, "wb") as handle:
            handle.write(bytes(rng.randrange(256) for _ in range(64)))
    elif choice == "truncated":
        with open(target, "rb") as handle:
            data = handle.read()
        with open(target, "wb") as handle:
            handle.write(data[: max(1, len(data) // 2)])
    else:
        # A real PNG header that claims absurd dimensions.
        header = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        header += (13).to_bytes(4, "big") + b"IHDR" + (0x7FFFFFFF).to_bytes(4, "big")
        header += (0x7FFFFFFF).to_bytes(4, "big") + bytes([8, 6, 0, 0, 0])
        with open(target, "wb") as handle:
            handle.write(header)
    return f"image {choice}"


def mutation_extreme_numbers(package, rng):
    path = os.path.join(package, "manifest.json")
    manifest = first_manifest(path)
    choice = rng.choice(["canvas", "opacity", "transform", "resolution", "version"])
    if choice == "canvas":
        manifest["width"] = rng.choice([0, -1, 10 ** 9, 2 ** 31, 2 ** 63 - 1])
        manifest["height"] = rng.choice([0, -5, 10 ** 9])
    elif choice == "opacity":
        rng.choice(manifest["layers"])["opacity"] = rng.choice([-1.0, 1e300, float("nan"), float("inf")])
    elif choice == "transform":
        layer = rng.choice(manifest["layers"])
        layer["transform"]["size"] = rng.choice([[0.0, 0.0], [-4.0, 8.0], [1e300, 1e300], [float("nan"), 2.0]])
    elif choice == "resolution":
        manifest["resolution"] = rng.choice([0, -72, 10 ** 9])
    else:
        manifest["version"] = rng.choice([0, 12, -1, 10 ** 9])
    write_manifest(path, manifest)
    return f"extreme {choice}"


def mutation_graph_abuse(package, rng):
    path = os.path.join(package, "manifest.json")
    manifest = first_manifest(path)
    layers = manifest["layers"]
    if len(layers) < 2:
        return None
    choice = rng.choice(["self-parent", "cycle", "clip-cycle", "deep-chain", "clip-forward"])
    if choice == "self-parent":
        layers[0]["parentID"] = layers[0]["id"]
    elif choice == "cycle":
        layers[0]["parentID"] = layers[1]["id"]
        layers[1]["parentID"] = layers[0]["id"]
    elif choice == "clip-cycle":
        layers[0]["maskSourceID"] = layers[1]["id"]
        layers[1]["maskSourceID"] = layers[0]["id"]
    elif choice == "deep-chain":
        for index in range(1, len(layers)):
            layers[index]["parentID"] = layers[index - 1]["id"]
            layers[index - 1]["isGroup"] = True
    else:
        layers[0]["maskSourceID"] = layers[-1]["id"]
    write_manifest(path, manifest)
    return f"graph abuse: {choice}"


MUTATIONS = [
    mutation_truncate, mutation_wrong_type, mutation_bad_uuid, mutation_bad_path,
    mutation_asset_damage, mutation_extreme_numbers, mutation_graph_abuse,
]


def run(cli, args, timeout):
    try:
        result = subprocess.run([cli] + args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timeout", ""
    output = (result.stdout or "") + (result.stderr or "")
    if "panicked at" in output or "RUST_BACKTRACE" in output:
        return result.returncode, "panic", output
    if result.returncode in CRASH_CODES or result.returncode < 0:
        return result.returncode, CRASH_CODES.get(result.returncode, f"crash code {result.returncode}"), output
    return result.returncode, "clean", output


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--per-fixture", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=25.0)
    parser.add_argument("--seed", type=int, default=4242)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args(argv)

    rng = random.Random(args.seed)
    fixtures = sorted(name for name in os.listdir(FIXTURES) if name.endswith(".comp"))
    work = tempfile.mkdtemp(prefix="comphostile-")
    if os.path.exists(FAILURES) and not args.keep:
        shutil.rmtree(FAILURES, ignore_errors=True)
    os.makedirs(FAILURES, exist_ok=True)
    tried = 0
    rejected = 0
    accepted = 0
    problems = []
    try:
        for name in fixtures:
            for round_index in range(args.per_fixture):
                package = os.path.join(work, f"case-{tried:04d}.comp")
                shutil.rmtree(package, ignore_errors=True)
                shutil.copytree(os.path.join(FIXTURES, name), package)
                mutation = rng.choice(MUTATIONS)
                description = mutation(package, rng)
                if description is None:
                    continue
                tried += 1
                for command in (["validate", package], ["render", package, "-o", os.path.join(work, "out.png")]):
                    code, kind, output = run(args.cli, command, args.timeout)
                    if kind != "clean":
                        problems.append((f"{name}: {description}", command[0], kind, output[:400]))
                        shutil.copytree(package, os.path.join(FAILURES, f"case-{tried:04d}"))
                        break
                    if command[0] == "validate":
                        if code == 0:
                            accepted += 1
                        else:
                            rejected += 1
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for where, command, kind, output in problems:
        print(f"FAIL {where} ({command}): {kind}")
        if kind == "panic":
            for line in output.splitlines():
                if "panicked" in line or "assertion" in line:
                    print(f"      {line.strip()[:150]}")
                    break
    print(f"{tried} damaged packages fed to validate+render: {rejected} refused cleanly, "
          f"{accepted} accepted, {len(problems)} crashed or hung")
    if problems:
        print(f"FAIL; the offending packages are in {FAILURES}")
        return 1
    print("PASS no damaged package panicked, crashed or hung")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
