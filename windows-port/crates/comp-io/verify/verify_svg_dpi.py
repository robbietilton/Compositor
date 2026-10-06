r"""Independent check of the SVG import and the resolution readers.

ImageMagick rasterizes the same SVG, Pillow writes the tagged files, and comp-io has to agree:

    $env:CARGO_TARGET_DIR = "E:\Compositor-main\compositor_win\target-raster-io"
    cargo build -p comp-io --example io_check
    python verify/verify_svg_dpi.py

Set COMP_IO_CHECK to the io_check binary when the target directory differs, and
COMP_IO_MAGICK to the ImageMagick executable when it is not on PATH.
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

EXE = os.environ.get(
    "COMP_IO_CHECK",
    r"E:\Compositor-main\compositor_win\target-raster-io\debug\examples\io_check.exe",
)
MAGICK = os.environ.get("COMP_IO_MAGICK", "magick")
WORK = os.path.join(tempfile.gettempdir(), "comp-io-svg-dpi")
os.makedirs(WORK, exist_ok=True)
RESULTS = []


def report(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + ((" -- " + detail) if detail else ""))


def run(*args):
    completed = subprocess.run([EXE, *args], capture_output=True, text=True)
    facts = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            facts[key] = value
    return facts, completed


def load(path):
    with Image.open(path) as image:
        return np.array(image.convert("RGBA")).astype(np.int64)


SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="64" height="48" viewBox="0 0 64 48">
  <rect width="64" height="48" fill="#f0e0c0"/>
  <rect x="6" y="6" width="24" height="16" fill="#3060c0"/>
  <circle cx="46" cy="16" r="9" fill="#c03030"/>
  <rect x="10" y="28" width="44" height="12" fill="#20a060" fill-opacity="0.6"/>
</svg>
"""
svg_path = os.path.join(WORK, "probe.svg")
open(svg_path, "w", encoding="utf-8").write(SVG)

# 1. The size the importer reports, and the drawing against ImageMagick's own rasterization.
facts, completed = run("import", svg_path)
report("svg import reports it was vector art", facts.get("format") == "SVG", facts.get("format", ""))
report("svg import keeps the declared size", (facts.get("width"), facts.get("height")) == ("64", "48"),
       f"{facts.get('width')}x{facts.get('height')} rc={completed.returncode}")
report("a vector file reports no dpi of its own", abs(float(facts.get("resolution", -1))) < 0.001,
       facts.get("resolution", ""))

mine = os.path.join(WORK, "mine.png")
run("export-png", svg_path, mine, "72")
theirs = os.path.join(WORK, "theirs.png")
subprocess.run([MAGICK, "-background", "none", svg_path, theirs], check=True, capture_output=True)
our_array = load(mine)
their_array = load(theirs)
report("the two rasterizations agree on the size", our_array.shape == their_array.shape,
       f"{our_array.shape} vs {their_array.shape}")
difference = np.abs(our_array[..., :3] - their_array[..., :3]).mean()
report("the two rasterizations agree on the picture", difference < 8.0,
       f"mean channel difference {difference:.2f}")
# Shapes must land in the same place even when the antialiasing does not.
ours_filled = our_array[..., :3].sum(-1) < 600
theirs_filled = their_array[..., :3].sum(-1) < 600
overlap = (ours_filled == theirs_filled).mean()
report("the shapes land where ImageMagick puts them", overlap > 0.97, f"{overlap * 100:.1f}% agreement")

# 2. TIFF resolution written by Pillow.
pattern = Image.new("RGB", (16, 16), (200, 40, 40))
tiff = os.path.join(WORK, "tagged.tiff")
pattern.save(tiff, dpi=(300, 300))
facts, _ = run("import", tiff)
report("pillow's 300 dpi tiff reads back", abs(float(facts.get("resolution", 0)) - 300) < 1,
       facts.get("resolution", ""))

# 3. BMP resolution written by ImageMagick, and the round trip out through PNG.
source = os.path.join(WORK, "source.png")
pattern.save(source)
bmp = os.path.join(WORK, "tagged.bmp")
subprocess.run([MAGICK, source, "-units", "PixelsPerInch", "-density", "300", bmp],
               check=True, capture_output=True)
facts, _ = run("import", bmp)
report("imagemagick's 300 dpi bmp reads back", abs(float(facts.get("resolution", 0)) - 300) < 1,
       facts.get("resolution", ""))
exported = os.path.join(WORK, "roundtrip.png")
run("export-png", bmp, exported, facts.get("resolution", "72"))
with Image.open(exported) as written:
    dpi = written.info.get("dpi")
report("the imported dpi is written back out", dpi is not None and abs(dpi[0] - 300) < 1, str(dpi))

# 4. WebP: ImageMagick tags nothing, Pillow writes an EXIF chunk that the reader must find.
untagged = os.path.join(WORK, "untagged.webp")
subprocess.run([MAGICK, source, untagged], check=True, capture_output=True)
facts, _ = run("import", untagged)
report("a webp with no exif reports no dpi", abs(float(facts.get("resolution", -1))) < 0.001,
       facts.get("resolution", ""))
exif = Image.Exif()
exif[282] = 300.0
exif[283] = 300.0
exif[296] = 2
tagged = os.path.join(WORK, "tagged.webp")
pattern.save(tagged, exif=exif.tobytes())
facts, _ = run("import", tagged)
report("pillow's 300 dpi webp reads back", abs(float(facts.get("resolution", 0)) - 300) < 1,
       facts.get("resolution", ""))

failed = [name for name, ok, _ in RESULTS if not ok]
print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
sys.exit(1 if failed else 0)
