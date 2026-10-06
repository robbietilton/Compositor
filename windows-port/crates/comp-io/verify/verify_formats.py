r"""Independent check of comp-io's raster formats against Pillow.

Two tools that were written separately have to agree on the same file:

    $env:CARGO_TARGET_DIR = "E:\Compositor-main\compositor_win\target-raster-io"
    cargo build -p comp-io --example io_check
    python verify/verify_formats.py

Set COMP_IO_CHECK to the io_check binary when the target directory differs.
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image

EXE = os.environ.get(
    "COMP_IO_CHECK",
    r"E:\Compositor-main\compositor_win\target-raster-io\debug\examples\io_check.exe",
)
WORK = os.path.join(tempfile.gettempdir(), "comp-io-verify")
os.makedirs(WORK, exist_ok=True)
RESULTS = []


def report(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + ((" -- " + detail) if detail else ""))


def fnv(data):
    """The same FNV-1a the io_check example prints for the straight RGBA bytes."""
    h = 0xCBF29CE484222325
    for byte in data:
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def run(*args):
    completed = subprocess.run([EXE, *args], capture_output=True, text=True)
    facts = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            facts[key] = value
    return facts, completed


W = H = 16
pattern = Image.new("RGBA", (W, H))
pattern.putdata([((x * 13) % 256, (y * 17) % 256, ((x + y) * 7) % 256, 255 if (x + y) % 3 else 128)
                 for y in range(H) for x in range(W)])
opaque = Image.new("RGBA", (W, H))
opaque.putdata([((x * 13) % 256, (y * 17) % 256, ((x + y) * 7) % 256, 255)
                for y in range(H) for x in range(W)])

png = os.path.join(WORK, "pattern.png")
pattern.save(png, dpi=(144, 144))
facts, _ = run("import", png)
report("png import returns the pixels", facts.get("checksum") == str(fnv(pattern.tobytes())))
report("png import reports the resolution", abs(float(facts.get("resolution", 0)) - 144) < 0.5,
       facts.get("resolution", ""))
report("png import reports the format", facts.get("format") == "PNG", facts.get("format", ""))

for name, saver, source in [
    ("tiff", lambda path: pattern.save(path), pattern),
    ("bmp", lambda path: opaque.convert("RGB").save(path), opaque),
    ("webp", lambda path: pattern.save(path, lossless=True, quality=100), pattern),
]:
    path = os.path.join(WORK, f"pattern.{name}")
    saver(path)
    facts, completed = run("import", path)
    expected = str(fnv(source.tobytes()))
    report(f"{name} import is lossless", facts.get("checksum") == expected, f"rc={completed.returncode}")

jpg = os.path.join(WORK, "photo.jpg")
pattern.convert("RGB").save(jpg, quality=95, dpi=(300, 300))
facts, _ = run("import", jpg)
report("jpeg import reports the resolution", abs(float(facts.get("resolution", 0)) - 300) < 1,
       facts.get("resolution", ""))
report("jpeg import reports the size", (facts.get("width"), facts.get("height")) == (str(W), str(H)))

out_png = os.path.join(WORK, "exported.png")
run("export-png", png, out_png, "300")
with Image.open(out_png) as written:
    dpi = written.info.get("dpi")
    same = written.convert("RGBA").tobytes() == pattern.tobytes()
report("exported png carries 300 dpi", dpi is not None and abs(dpi[0] - 300) < 1, str(dpi))
report("exported png keeps the pixels", same)

out_jpg = os.path.join(WORK, "exported.jpg")
run("export-jpeg", png, out_jpg, "95", "200")
with Image.open(out_jpg) as written:
    dpi = written.info.get("dpi")
    flattened = Image.alpha_composite(Image.new("RGBA", (W, H), (255, 255, 255, 255)), pattern).convert("RGB")
    difference = sum(abs(a - b) for a, b in zip(written.convert("RGB").tobytes(), flattened.tobytes()))
    mean = difference / (W * H * 3)
report("exported jpeg carries 200 dpi", dpi is not None and abs(dpi[0] - 200) < 1, str(dpi))
report("exported jpeg is close to the flattened source", mean < 6, f"mean channel difference {mean:.2f}")

failed = [name for name, ok, _ in RESULTS if not ok]
print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
sys.exit(1 if failed else 0)
