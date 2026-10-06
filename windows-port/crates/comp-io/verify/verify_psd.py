r"""Independent check of comp-io's Photoshop reader against ImageMagick and Pillow.

ImageMagick writes the files, Pillow confirms they are valid, and comp-io has to agree with both:

    $env:CARGO_TARGET_DIR = "E:\Compositor-main\compositor_win\target-raster-io"
    cargo build -p comp-io --example io_check
    python verify/verify_psd.py

Set COMP_IO_CHECK to the io_check binary when the target directory differs, and
COMP_IO_MAGICK to the ImageMagick executable when it is not on PATH.
"""
import os
import struct
import subprocess
import sys
import tempfile

from PIL import Image

EXE = os.environ.get(
    "COMP_IO_CHECK",
    r"E:\Compositor-main\compositor_win\target-raster-io\debug\examples\io_check.exe",
)
MAGICK = os.environ.get("COMP_IO_MAGICK", "magick")
WORK = os.path.join(tempfile.gettempdir(), "comp-io-psd-verify")
os.makedirs(WORK, exist_ok=True)
RESULTS = []


def report(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + ((" -- " + detail) if detail else ""))


def fnv(data):
    h = 0xCBF29CE484222325
    for byte in data:
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def run(*args):
    completed = subprocess.run([EXE, *args], capture_output=True, text=True)
    facts, layers, conversions = {}, [], []
    for line in completed.stdout.splitlines():
        if line.startswith("layer="):
            layers.append(line[len("layer="):])
        elif line.startswith("conversion="):
            conversions.append(line[len("conversion="):])
        elif "=" in line:
            key, value = line.split("=", 1)
            facts[key] = value
    return facts, layers, conversions, completed


def strip_layers(source, target):
    """Removes the layer and mask section, the way Photoshop writes a flattened file."""
    data = bytearray(open(source, "rb").read())
    assert data[:4] == b"8BPS", "not a psd"
    offset = 26
    color_mode = struct.unpack(">I", data[offset:offset + 4])[0]
    offset += 4 + color_mode
    resources = struct.unpack(">I", data[offset:offset + 4])[0]
    offset += 4 + resources
    section = struct.unpack(">I", data[offset:offset + 4])[0]
    merged = data[offset + 4 + section:]
    open(target, "wb").write(bytes(data[:offset]) + struct.pack(">I", 0) + bytes(merged))
    return section


W = H = 16
pattern = Image.new("RGB", (W, H))
pattern.putdata([((x * 13) % 256, (y * 17) % 256, ((x + y) * 7) % 256) for y in range(H) for x in range(W)])
png = os.path.join(WORK, "pattern.png")
pattern.save(png)
expected = str(fnv(pattern.convert("RGBA").tobytes()))

flat = os.path.join(WORK, "flat300.psd")
subprocess.run([MAGICK, png, "-units", "PixelsPerInch", "-density", "300", flat], check=True)
with Image.open(flat) as sanity:
    report("imagemagick writes a psd pillow can open", sanity.size == (W, H), str(sanity.size))
facts, layers, conversions, completed = run("psd", flat)
checksums = [entry.split("checksum=")[1].split("|")[0] for entry in layers]
report("imagemagick psd reads with its layers", facts.get("layers") == "1", f"layers={facts.get('layers')}")
report("imagemagick psd pixels match", checksums == [expected], f"{checksums} vs {expected}")
report("imagemagick psd resolution comes from its resource",
       abs(float(facts.get("resolution", 0)) - 300) < 1, facts.get("resolution", ""))
report("imagemagick psd reports no conversions", facts.get("conversions") == "0", "; ".join(conversions))

merged = os.path.join(WORK, "merged.psd")
strip_layers(flat, merged)
with Image.open(merged) as sanity:
    report("a layerless psd still opens in pillow", sanity.size == (W, H), str(sanity.size))
facts, layers, conversions, completed = run("psd", merged)
checksums = [entry.split("checksum=")[1].split("|")[0] for entry in layers]
report("layerless psd decodes its merged image", facts.get("layers") == "1" and checksums == [expected],
       f"layers={facts.get('layers')}, {checksums}")
report("layerless psd says why it is one layer",
       any("no layer records" in note for note in conversions), "; ".join(conversions))
report("layerless psd keeps the resolution", abs(float(facts.get("resolution", 0)) - 300) < 1,
       facts.get("resolution", ""))

cmyk = os.path.join(WORK, "cmyk.psd")
subprocess.run([MAGICK, png, "-colorspace", "CMYK", cmyk], check=True)
facts, _, _, completed = run("psd", cmyk)
report("cmyk psd is refused with a reason", completed.returncode != 0 and "CMYK" in facts.get("error", ""),
       facts.get("error", ""))

failed = [name for name, ok, _ in RESULTS if not ok]
print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
sys.exit(1 if failed else 0)
