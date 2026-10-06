"""Independent oracle for the vendor raw front end, from the DNG and TIFF specifications.

```comp-raw/tests/vendor.rs``` writes a synthetic DNG and the three planes its decoder produced
(`COMP_RAW_ORACLE_DIR=<dir> cargo test -p comp-raw --test vendor the_oracle_fixture_is_written_when_asked`).
This script parses that DNG with its own TIFF reader — no Rust, no rawloader — and recomputes the whole
front end with NumPy: black/white levels, as-shot white balance, bilinear demosaic, camera matrix and
the sRGB transfer function. It prints the largest difference at every stage.

    python tools/vendor_oracle.py <oracle-dir>
"""
import struct
import sys
from pathlib import Path

import numpy as np

RGB_TO_XYZ = np.array([
    [0.412453, 0.357580, 0.180423],
    [0.212671, 0.715160, 0.072169],
    [0.019334, 0.119193, 0.950227],
])

TYPE_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}


def parse_tiff(data):
    """Returns the tags of the first IFD as {tag: (type, count, raw_bytes)}."""
    endian = "<" if data[0:2] == b"II" else ">"
    magic, ifd_offset = struct.unpack(endian + "HI", data[2:8])
    assert magic == 42, "not a TIFF container"
    count = struct.unpack(endian + "H", data[ifd_offset:ifd_offset + 2])[0]
    tags = {}
    for index in range(count):
        entry = ifd_offset + 2 + index * 12
        tag, kind, tag_count = struct.unpack(endian + "HHI", data[entry:entry + 8])
        size = TYPE_SIZES.get(kind, 1) * tag_count
        if size <= 4:
            payload = data[entry + 8:entry + 8 + size]
        else:
            offset = struct.unpack(endian + "I", data[entry + 8:entry + 12])[0]
            payload = data[offset:offset + size]
        tags[tag] = (kind, tag_count, payload)
    return endian, tags


def values(tags, tag, endian, signed=False):
    kind, count, payload = tags[tag]
    if kind == 5:
        pairs = [struct.unpack(endian + "II", payload[i * 8:i * 8 + 8]) for i in range(count)]
        return np.array([a / b for a, b in pairs], dtype=np.float64)
    if kind == 10:
        pairs = [struct.unpack(endian + "ii", payload[i * 8:i * 8 + 8]) for i in range(count)]
        return np.array([a / b for a, b in pairs], dtype=np.float64)
    if kind == 3:
        return np.array(struct.unpack(endian + str(count) + "H", payload), dtype=np.float64)
    if kind == 4:
        return np.array(struct.unpack(endian + str(count) + "I", payload), dtype=np.float64)
    if kind == 1:
        return np.array(list(payload[:count]), dtype=np.float64 if not signed else np.int64)
    raise AssertionError(f"unhandled type {kind}")


def box_blur(plane, radius):
    """Edge-clamped box blur, the same running window the C kernel and the Rust port use."""
    height, width = plane.shape
    window = 2 * radius + 1
    padded = np.pad(plane, ((0, 0), (radius, radius)), mode="edge")
    cumulative = np.cumsum(padded, axis=1)
    sums = cumulative[:, 2 * radius:] - np.concatenate([np.zeros((height, 1)), cumulative[:, :-window]], axis=1)
    temp = sums / window
    padded = np.pad(temp, ((radius, radius), (0, 0)), mode="edge")
    cumulative = np.cumsum(padded, axis=0)
    sums = cumulative[2 * radius:, :] - np.concatenate([np.zeros((1, width)), cumulative[:-window, :]], axis=0)
    return sums / window


def demosaic(mosaic, colors, radius=1):
    planes = []
    for color in range(3):
        own = colors == color
        values = np.where(own, mosaic, 0.0)
        mask = own.astype(np.float64)
        blurred_values = box_blur(values, radius)
        blurred_mask = box_blur(mask, radius)
        planes.append(np.where(blurred_mask > 1e-6, blurred_values / np.maximum(blurred_mask, 1e-12), 0.0))
    out = np.stack(planes, axis=-1)
    for color in range(3):
        own = colors == color
        out[..., color] = np.where(own, mosaic, out[..., color])
    return out


def camera_to_srgb(xyz_to_cam):
    """dcraw's cam_xyz_coeff: scale each camera channel so white answers 1, then invert."""
    cam_rgb = xyz_to_cam @ RGB_TO_XYZ
    cam_rgb = cam_rgb / cam_rgb.sum(axis=1, keepdims=True)
    return np.linalg.inv(cam_rgb)


def encode_srgb(linear):
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * np.power(linear, 1.0 / 2.4) - 0.055)


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    data = (directory / "synthetic.dng").read_bytes()
    endian, tags = parse_tiff(data)

    width = int(values(tags, 0x0100, endian)[0])
    height = int(values(tags, 0x0101, endian)[0])
    samples_per_pixel = int(values(tags, 0x0115, endian)[0])
    photometric = int(values(tags, 0x0106, endian)[0])
    white = values(tags, 0xC61D, endian)[0]
    black = values(tags, 0xC61A, endian)[0] if 0xC61A in tags else 0.0
    cfa = list(values(tags, 0x828E, endian).astype(int)) if 0x828E in tags else None
    neutral = values(tags, 0xC628, endian) if 0xC628 in tags else None
    matrix = values(tags, 0xC621, endian).reshape(3, 3) if 0xC621 in tags else None
    strip = int(values(tags, 0x0111, endian)[0])

    print(f"DNG {width}x{height} samplesPerPixel={samples_per_pixel} photometric={photometric}")
    print(f"  black={black} white={white} cfa={cfa} asShotNeutral={neutral}")
    print(f"  colorMatrix1=\n{matrix if matrix is not None else 'none (rawloader substitutes sRGB primaries)'}")

    total = width * height * samples_per_pixel
    samples = np.frombuffer(data[strip:strip + total * 2], dtype=endian + "u2").astype(np.float64)
    assert samples.size == total, f"{samples.size} samples for {total}"

    # Each sample's filter color: from the CFA pattern, or from its position in a linear raw.
    if samples_per_pixel == 1:
        colors = np.zeros(total, dtype=np.int64)
        for y in range(height):
            for x in range(width):
                colors[y * width + x] = cfa[(y % 2) * 2 + (x % 2)]
    else:
        colors = np.tile(np.arange(3), total // 3 + 1)[:total]

    normalized = (samples - black) / (white - black)
    normalized = np.clip(normalized, 0.0, 1.0)

    # rawloader turns AsShotNeutral into multipliers by inverting it, and the port green-normalizes them.
    if neutral is not None:
        multipliers = 1.0 / neutral
        multipliers = multipliers / multipliers[1]
        source = "Camera"
    else:
        raise AssertionError("this fixture is expected to carry AsShotNeutral")
    balanced = normalized * multipliers[colors]
    print(f"  white balance {multipliers} ({source})")

    # Third opinion on the mosaic itself: Pillow's TIFF reader must see the same 16-bit samples, so a
    # mistake in this script's own tag parsing cannot hide behind the comparison below.
    try:
        from PIL import Image

        with Image.open(directory / "synthetic.dng") as pillow_image:
            pillow_pixels = np.asarray(pillow_image).astype(np.float64)
        if pillow_pixels.shape == (height, width):
            pillow_diff = float(np.max(np.abs(samples.reshape(height, width) - pillow_pixels)))
            print(f"  Pillow CFA      max|diff| = {pillow_diff:.3e}")
        else:
            print(f"  Pillow CFA      shape {pillow_pixels.shape}, not compared")
    except Exception as error:  # Pillow is optional; the NumPy path above stands on its own.
        print(f"  Pillow CFA      unavailable ({error.__class__.__name__}: {error})")

    # The mosaic plane the decoder reports.
    reference_mosaic = np.fromfile(directory / "synthetic.mosaic.f32", dtype="<f4").astype(np.float64)
    mosaic_diff = float(np.max(np.abs(balanced - reference_mosaic)))
    print(f"  mosaic plane    max|diff| = {mosaic_diff:.3e}")

    if samples_per_pixel == 1:
        rgb = demosaic(balanced.reshape(height, width), colors.reshape(height, width))
    else:
        rgb = balanced.reshape(height, width, 3)
    matrix_used = camera_to_srgb(matrix) if matrix is not None else np.eye(3)
    linear = rgb @ matrix_used.T
    reference_linear = np.fromfile(directory / "synthetic.linear.f32", dtype="<f4").astype(np.float64).reshape(height, width, 3)
    linear_diff = float(np.max(np.abs(linear - reference_linear)))
    print(f"  camera matrix   max|diff| = {linear_diff:.3e}")

    encoded = np.round(encode_srgb(linear) * 255.0).astype(np.uint8)
    reference_bytes = np.frombuffer((directory / "synthetic.rgba8.raw").read_bytes(), dtype=np.uint8)
    reference_rgb = reference_bytes.reshape(height, width, 4)[..., :3]
    byte_diff = int(np.max(np.abs(encoded.astype(np.int64) - reference_rgb.astype(np.int64))))
    print(f"  sRGB bytes      max|diff| = {byte_diff}")

    tolerance = 1e-5
    ok = mosaic_diff < tolerance and linear_diff < 1e-4 and byte_diff <= 1
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
