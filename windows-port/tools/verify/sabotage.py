"""Runs the real CLI and then spoils what it produced, so the checks can be tested.

A check that always passes is worse than no check: it costs a run and reports safety that is not there.
This wrapper is handed to a check in place of compc. It forwards every command to the real tool, then
damages the workspace in a way the check exists to notice: renders come out slightly different every
time, and "validate" always claims success.

Usage: python sabotage.py <real-cli> <arguments...>
"""

from __future__ import annotations

import os
import subprocess
import sys

COUNTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sabotage-count.txt")


def next_shift():
    try:
        with open(COUNTER, "r", encoding="utf-8") as handle:
            value = int(handle.read().strip() or "0")
    except (OSError, ValueError):
        value = 0
    value += 1
    with open(COUNTER, "w", encoding="utf-8") as handle:
        handle.write(str(value))
    return value


def spoil(path, shift):
    """Changes one pixel, and only the pixels.

    Two earlier versions were too gentle and let a broken render through: one flipped a byte in the
    IEND trailer, which decoders ignore, and one flipped a byte in the middle, which sometimes lands in
    a chunk that does not affect the image. Decoding and re-encoding with one pixel changed cannot
    miss.
    """
    if not os.path.isfile(path):
        return
    try:
        from PIL import Image
    except ImportError:
        return
    try:
        with Image.open(path) as image:
            image.load()
            pixels = image.copy()
    except Exception:
        return
    if pixels.width == 0 or pixels.height == 0:
        return
    at = ((shift * 7) % pixels.width, (shift * 13) % pixels.height)
    value = pixels.getpixel(at)
    if isinstance(value, int):
        changed = (value + 64) % 256
    else:
        channel = list(value)
        channel[0] = (channel[0] + 64) % 256
        changed = tuple(channel)
    pixels.putpixel(at, changed)
    try:
        pixels.save(path)
    except Exception:
        pass


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cli, arguments = argv[1], argv[2:]
    result = subprocess.run([cli] + arguments, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if arguments and arguments[0] == "validate":
        return 0
    if arguments:
        spoil(arguments[-1], next_shift())
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
