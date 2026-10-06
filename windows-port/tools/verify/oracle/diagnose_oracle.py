"""Shows where one fixture's render and the oracle disagree.

Run:  python diagnose_oracle.py --name effect-coloroverlay
      python diagnose_oracle.py --name effect-coloroverlay --row 27

Prints the bounding boxes of what each image changed from the plain chart, a coarse map of the
difference, and the pixels along one row, which is enough to tell a shifted effect from a wrong
kernel or a wrong formula.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(ROOT, "fixtures-oracle")


def load(path):
    with Image.open(path) as image:
        return np.asarray(image.convert("RGBA"), dtype=np.int64)


def bounds(mask):
    if not mask.any():
        return None
    rows = np.nonzero(mask.any(axis=1))[0]
    columns = np.nonzero(mask.any(axis=0))[0]
    return (int(columns[0]), int(rows[0]), int(columns[-1]), int(rows[-1]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--row", type=int, default=None)
    parser.add_argument("--column", type=int, default=None)
    arguments = parser.parse_args()

    base = load(os.path.join(FIXTURES, "expected", "control-base.png"))
    expected = load(os.path.join(FIXTURES, "expected", arguments.name + ".png"))
    actual = load(os.path.join(FIXTURES, "actual", arguments.name + ".png"))
    print("name        %s" % arguments.name)
    print("changed by oracle  %s" % (bounds(np.abs(expected - base).max(axis=2) > 0),))
    print("changed by render  %s" % (bounds(np.abs(actual - base).max(axis=2) > 0),))
    difference = np.abs(expected - actual).max(axis=2)
    print("disagreement       %s  worst %d" % (bounds(difference > 1), difference.max()))

    if arguments.row is not None:
        row = arguments.row
        print("\nrow %d" % row)
        print("x    base            oracle          render")
        for x in range(base.shape[1]):
            if np.abs(expected[row, x] - actual[row, x]).max() > 0 or np.abs(expected[row, x] - base[row, x]).max() > 0:
                print("%3d  %-15s %-15s %-15s" % (x, list(base[row, x]), list(expected[row, x]), list(actual[row, x])))
    if arguments.column is not None:
        column = arguments.column
        print("\ncolumn %d" % column)
        print("y    base            oracle          render")
        for y in range(base.shape[0]):
            if np.abs(expected[y, column] - actual[y, column]).max() > 0 or np.abs(expected[y, column] - base[y, column]).max() > 0:
                print("%3d  %-15s %-15s %-15s" % (y, list(base[y, column]), list(expected[y, column]), list(actual[y, column])))

    if arguments.row is None and arguments.column is None:
        coarse = difference[::4, ::4]
        print("\ndifference every 4th pixel (0-9, . = none)")
        for line in coarse:
            print("".join("." if value == 0 else str(min(9, int(value) // 26 + 1)) for value in line))
        with open(os.path.join(FIXTURES, "index.json"), "r", encoding="utf-8") as handle:
            index = json.load(handle)
        record = next((entry for entry in index["fixtures"] if entry["name"] == arguments.name), None)
        if record:
            print("\nnote: %s" % record["note"])


if __name__ == "__main__":
    main()
