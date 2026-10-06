"""Writes the codec reference files the comp-io tests import.

Every file here is produced by Pillow, an implementation of the formats that shares no code with
this crate, and the expected pixels are Pillow's own decode of the file it just wrote. A test that
compares the two therefore measures this crate against a second implementation, which is the only
way to catch a decoder and an encoder that are wrong in the same way.

Pillow cannot write 16-bit RGB or RGBA PNGs (only 16-bit grayscale), so those cases are built by
the Rust unit tests with the png crate instead.

Run from this directory:  python make_codec_fixtures.py
"""
from __future__ import annotations

import json
import os
import struct

import numpy as np
from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")


def sample(width, height, channels, seed):
    rng = np.random.default_rng(seed)
    if channels == 1:
        return (rng.random((height, width)) * 255).astype(np.uint8)
    array = (rng.random((height, width, channels)) * 255).astype(np.uint8)
    return array


def exif_orientation(orientation):
    """A little-endian Exif block carrying only an orientation tag."""
    body = (struct.pack("<H", 1)
            + struct.pack("<HHI", 0x0112, 3, 1) + struct.pack("<HH", orientation, 0)
            + struct.pack("<I", 0))
    return b"II\x2a\x00" + struct.pack("<I", 8) + body


def exif_dpi(dpi):
    """A little-endian Exif block with XResolution, YResolution and an inch resolution unit."""
    rationals_at = 50  # eight bytes of header, the entry count, three entries and the next offset
    body = (struct.pack("<H", 3)
            + struct.pack("<HHI", 0x011A, 5, 1) + struct.pack("<I", rationals_at)
            + struct.pack("<HHI", 0x011B, 5, 1) + struct.pack("<I", rationals_at + 8)
            + struct.pack("<HHI", 0x0128, 3, 1) + struct.pack("<HH", 2, 0)
            + struct.pack("<I", 0)
            + struct.pack("<II", dpi, 1) + struct.pack("<II", dpi, 1))
    return b"II\x2a\x00" + struct.pack("<I", 8) + body


def photo(width, height):
    """A smooth, photo-like picture.

    The chroma varies slowly on purpose: two HEVC decoders upsample it differently, and on a steep
    gradient that difference reaches double digits, which would say more about the test picture than
    about the importer.
    """
    xx, yy = np.meshgrid(
        np.linspace(0.0, 1.0, width, dtype=np.float64),
        np.linspace(0.0, 1.0, height, dtype=np.float64),
    )
    tones = np.dstack([100 + 60 * xx, 120 + 50 * yy, 140 - 40 * xx * yy])
    return np.clip(tones, 0, 255).astype(np.uint8)


def dump(name, array):
    path = os.path.join(OUT, name)
    with open(path, "wb") as handle:
        handle.write(array.tobytes())
    return name


def main():
    os.makedirs(OUT, exist_ok=True)
    index = []
    width, height = 24, 18

    # A 16-bit grayscale PNG with values that are not multiples of 257, so rounding decides the
    # result instead of the high byte alone.
    rng = np.random.default_rng(7)
    wide = rng.integers(0, 65536, size=(height, width), dtype=np.uint16)
    wide[0, 0], wide[0, 1], wide[0, 2] = 0, 32768, 65535
    wide[0, 3], wide[0, 4], wide[0, 5] = 1, 128, 129
    path = os.path.join(OUT, "png_gray16.png")
    Image.fromarray(wide).save(path)
    scaled = np.round(wide.astype(np.float64) * 255.0 / 65535.0).astype(np.uint8)
    expected = np.dstack([scaled] * 3 + [np.full((height, width), 255, np.uint8)])
    index.append({
        "name": "png-gray16",
        "file": "png_gray16.png",
        "expected": dump("png_gray16.rgba", expected),
        "width": width,
        "height": height,
        "tolerance": 0,
        "note": "16-bit grayscale scaled with round(v * 255 / 65535)",
    })

    rgb = sample(width, height, 3, 1)
    gray = sample(width, height, 1, 3)
    alpha = np.where(np.random.default_rng(5).random((height, width)) < 0.4, 0, 255).astype(np.uint8)
    odd_width, odd_height = 23, 17
    odd_rgb = sample(odd_width, odd_height, 3, 6)
    tiny = sample(2, 2, 3, 9)
    for name, array, mode, tolerance in (("rgb", rgb, "RGB", 0), ("gray", gray, "L", 0)):
        file_name = "png_%s8.png" % name
        Image.fromarray(array, mode).save(os.path.join(OUT, file_name))
        if mode == "RGB":
            expect = np.dstack([array, np.full((height, width), 255, np.uint8)])
        else:
            expect = np.dstack([array] * 3 + [np.full((height, width), 255, np.uint8)])
        index.append({
            "name": "png-%s8" % name,
            "file": file_name,
            "expected": dump("png_%s8.rgba" % name, expect),
            "width": width,
            "height": height,
            "tolerance": tolerance,
            "note": "8-bit PNG, the path the package codec already owns",
        })

    # JPEG at every chroma sampling Pillow can write, plus grayscale. The expectation is Pillow's
    # decode of the same bytes, so a decoder that upsamples chroma differently shows up here.
    for name, subsampling, quality, source, mode in (
        ("jpeg-444", 0, 95, rgb, "RGB"),
        ("jpeg-422", 1, 92, rgb, "RGB"),
        ("jpeg-420", 2, 90, rgb, "RGB"),
        ("jpeg-gray", "4:2:0", 92, gray, "L"),
    ):
        file_name = name.replace("-", "_") + ".jpg"
        path = os.path.join(OUT, file_name)
        Image.fromarray(source, mode).save(path, quality=quality, subsampling=subsampling)
        with Image.open(path) as reopened:
            expect = np.asarray(reopened.convert("RGBA"), dtype=np.uint8)
        index.append({
            "name": name,
            "file": file_name,
            "expected": dump(name.replace("-", "_") + ".rgba", expect),
            "width": width,
            "height": height,
            "tolerance": 4 if name == "jpeg-420" else 3,
            "note": "Pillow encoded, Pillow decoded",
        })

    # HEIC: libheif writes the files through pillow-heif, and libheif's own decode is the
    # expectation. The Windows codec decodes the same bitstream, so the two agree closely when the
    # file says which color matrix it used.
    #
    # libheif's encoder defaults write a video usability matrix of BT.709 while the container
    # declares BT.601, and the Windows codec follows the bitstream: saturated colors then differ by
    # up to 39 levels between the two decoders. Real cameras write both the same way, so the color
    # cases here set the matrix explicitly. Grayscale needs no matrix at all, which makes it the
    # strongest cross-check of everything else (geometry, stride and alpha).
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except ImportError:
        print("pillow-heif is missing: run 'pip install pillow-heif' to regenerate the HEIC cases")
    else:
        matrix = pillow_heif.HeifMatrixCoefficients.ITU_R_BT_709_5
        soft = photo(width, height)
        heic_cases = [
            ("heic-gray", np.dstack([gray] * 3), "RGB", (width, height), None, 0),
            ("heic-soft", soft, "RGB", (width, height), matrix, 4),
            # An odd width leaves the chroma plane's edge in the middle of a pixel pair, and the two
            # decoders then differ by up to ten levels across the whole picture. The geometry is what
            # this case checks, so its tolerance covers the decoder disagreement.
            ("heic-odd", photo(odd_width, odd_height), "RGB", (odd_width, odd_height), matrix, 12),
        ]
        for name, source, mode, size, coefficients, tolerance in heic_cases:
            file_name = name.replace("-", "_") + ".heic"
            path = os.path.join(OUT, file_name)
            options = {} if coefficients is None else {"matrix_coefficients": coefficients}
            Image.fromarray(source, mode).save(path, quality=90, **options)
            with Image.open(path) as reopened:
                expect = np.asarray(reopened.convert("RGBA"), dtype=np.uint8)
            assert expect.shape[:2] == (size[1], size[0]), (name, expect.shape, size)
            index.append({
                "name": name,
                "file": file_name,
                "expected": dump(name.replace("-", "_") + ".rgba", expect),
                "width": size[0],
                "height": size[1],
                "tolerance": tolerance,
                "note": "libheif wrote and decoded the file",
            })
        # Two files the index leaves out, because they document behavior no tolerance can express.
        # A 2x2 picture is refused by the system decoder with E_INVALIDARG, and a picture with an
        # auxiliary alpha image comes back opaque: the decoder reports 24bppBGR and never exposes
        # the alpha item. Both are read by unit tests instead.
        # A file that declares a resolution, for the Exif item reader: the Windows metadata reader
        # does not expose these tags, so the container is parsed instead. It is not in the pixel
        # index, because what it tests is the resolution the document ends up with.
        Image.fromarray(photo(width, height), "RGB").save(
            os.path.join(OUT, "heic_dpi.heic"), quality=90, exif=exif_dpi(300)
        )
        print("wrote heic_dpi.heic a file declaring 300 dpi")
        Image.fromarray(tiny, "RGB").save(os.path.join(OUT, "heic_too_small.heic"), quality=90)
        Image.fromarray(np.dstack([soft, alpha]), "RGBA").save(
            os.path.join(OUT, "heic_alpha.heic"), quality=90, matrix_coefficients=matrix
        )
        print("wrote heic_too_small.heic and heic_alpha.heic for the tests that document limits")

    # AVIF: the same container coded with AV1. The system HEIF decoder reads it too, so the import
    # path is the same and the expectations come from libheif as well.
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except ImportError:
        print("pillow-heif is missing: run 'pip install pillow-heif' to regenerate the AVIF cases")
    else:
        for name, source, mode, tolerance in (
            ("avif-gray", np.dstack([gray] * 3), "RGB", 0),
            # The two AV1 decoders disagree more than the HEVC pair do; grayscale above is the
            # exact check, and this case covers colour at the tolerance of two decoders.
            ("avif-soft", photo(width, height), "RGB", 12),
        ):
            file_name = name.replace("-", "_") + ".avif"
            path = os.path.join(OUT, file_name)
            Image.fromarray(source, mode).save(path, quality=90, matrix_coefficients=matrix)
            with Image.open(path) as reopened:
                expect = np.asarray(reopened.convert("RGBA"), dtype=np.uint8)
            index.append({
                "name": name,
                "file": file_name,
                "expected": dump(name.replace("-", "_") + ".rgba", expect),
                "width": width,
                "height": height,
                "tolerance": tolerance,
                "note": "libheif wrote and decoded the file",
            })

        # Every EXIF orientation Pillow can write into an AVIF, with Pillow's own transpose as the
        # expectation: the reference is a second implementation of the tag, not this crate.
        oriented = photo(12, 8)
        for orientation in range(1, 9):
            file_name = "avif_orientation_%d.avif" % orientation
            path = os.path.join(OUT, file_name)
            Image.fromarray(oriented, "RGB").save(
                path, quality=95, matrix_coefficients=matrix, exif=exif_orientation(orientation)
            )
            with Image.open(path) as reopened:
                if reopened.getexif().get(274) != orientation:
                    print("orientation %d did not survive the writer; skipping" % orientation)
                    continue
                expect = np.asarray(ImageOps.exif_transpose(reopened).convert("RGBA"), dtype=np.uint8)
            index.append({
                "name": "avif-orientation-%d" % orientation,
                "file": file_name,
                "expected": dump("avif_orientation_%d.rgba" % orientation, expect),
                "width": expect.shape[1],
                "height": expect.shape[0],
                # The tolerance covers the two AV1 decoders, not the rotation: a wrong rotation
                # moves whole quadrants and lands far outside it.
                "tolerance": 12,
                "note": "EXIF orientation %d applied, Pillow's transpose is the expectation" % orientation,
            })

    with open(os.path.join(OUT, "index.json"), "w", encoding="utf-8") as handle:
        json.dump({"cases": index}, handle, indent=2, sort_keys=True)
        handle.write("\n")
    for case in index:
        print("wrote", case["file"], case["note"])
    print("fixtures are in", OUT)


if __name__ == "__main__":
    main()
