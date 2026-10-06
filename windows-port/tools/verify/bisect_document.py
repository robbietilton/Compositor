"""Finds which layer of a package makes the engine disagree with the oracle.

Builds a copy per step, hiding every layer above a growing prefix, renders each with compc and
compares against the reference implementation. Prints one line per step so the first divergence
names the layer responsible.

Run: python bisect_document.py <package.comp>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

import comp_reference as R

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "..", "..", "target-lead", "debug", "compc.exe")


def main(argv):
    package = os.path.abspath(argv[1] if len(argv) > 1 else "")
    if not os.path.isdir(package):
        print(__doc__)
        return 2
    with open(os.path.join(package, "manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    # A child must stay visible with its folder, so order the steps by the layer list itself and
    # keep every ancestor of a visible layer visible too.
    order = [record["id"] for record in manifest["layers"]]
    parents = {record["id"]: record.get("parentID") for record in manifest["layers"]}

    with tempfile.TemporaryDirectory() as work:
        for step in range(1, len(order) + 1):
            visible = set(order[:step])
            changed = True
            while changed:
                changed = False
                for layer_id in list(visible):
                    parent = parents.get(layer_id)
                    if parent and parent not in visible:
                        visible.add(parent)
                        changed = True
            target = os.path.join(work, f"step{step}.comp")
            if os.path.exists(target):
                shutil.rmtree(target)
            shutil.copytree(package, target)
            path = os.path.join(target, "manifest.json")
            with open(path, encoding="utf-8") as handle:
                step_manifest = json.load(handle)
            for record in step_manifest["layers"]:
                record["isVisible"] = record["id"] in visible
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(step_manifest, handle, indent=2, sort_keys=True)

            rendered = os.path.join(work, f"step{step}.png")
            process = subprocess.run([os.path.abspath(CLI), "render", target, "-o", rendered],
                                     capture_output=True, text=True)
            if process.returncode != 0:
                print(f"step {step}: render failed: {process.stderr.strip()[:120]}")
                continue
            _, images, masks = R.read_comp(target)
            expected = R.array_to_rgba_image(R.composite_document(step_manifest, images, masks))
            expected_path = os.path.join(work, f"step{step}-expected.png")
            expected.save(expected_path)
            a = np.asarray(Image.open(expected_path).convert("RGBA"), dtype=np.int16)
            b = np.asarray(Image.open(rendered).convert("RGBA"), dtype=np.int16)
            diff = np.abs(a - b)
            names = ", ".join(
                record["name"] for record in step_manifest["layers"] if record["id"] in visible
            )
            print(f"step {step}: worst={int(diff.max())} mean={diff.mean():.4f} "
                  f"mismatched={int((diff.max(axis=-1) > 1).sum())} visible=[{names}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
