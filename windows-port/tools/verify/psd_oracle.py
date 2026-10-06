"""Writes PSD files from scratch, so the importer can be checked against something it did not write.

comp-io has an independent reader for .comp (the oracle) and an independent validator for the manifest
(the macOS interop port), but PSD import was only covered by its own unit tests. This module writes real
PSD bytes by hand -- header, colour mode data, image resources, layer and mask information, channel data
with both raw and RLE compression -- and also computes what the merged image must look like. The importer
then has to agree with a second implementation of the format.

Usage: imported by check_psd.ps1 / verify_psd.py.
"""

from __future__ import annotations

import struct

import numpy as np

# PSD blend mode keys, four characters each.
BLEND_KEYS = {
    "Normal": b"norm",
    "Multiply": b"mul ",
    "Screen": b"scrn",
    "Overlay": b"over",
    "Darken": b"dark",
    "Lighten": b"lite",
}


def _pascal_name(name: str, pad_to: int = 4) -> bytes:
    """Names are length-prefixed and padded to a multiple of four bytes."""
    raw = name.encode("macroman", errors="replace")[:255]
    data = bytes([len(raw)]) + raw
    while len(data) % pad_to:
        data += b"\x00"
    return data


def _rle_encode_plane(plane: np.ndarray) -> bytes:
    """PackBits, the compression PSD uses: a byte count followed by literal or repeated runs."""
    data = plane.astype(np.uint8).tobytes()
    out = bytearray()
    index = 0
    length = len(data)
    while index < length:
        run_end = index
        while run_end + 1 < length and data[run_end + 1] == data[index] and run_end - index < 126:
            run_end += 1
        run = run_end - index
        if run >= 1:
            out.append(257 - (run + 1))
            out.append(data[index])
            index = run_end + 1
        else:
            literal_end = index
            while literal_end + 1 < length and literal_end - index < 127:
                if literal_end + 2 < length and data[literal_end + 1] == data[literal_end + 2]:
                    break
                literal_end += 1
            count = literal_end - index + 1
            out.append(count - 1)
            out.extend(data[index:index + count])
            index += count
    return bytes(out)


def _pack_bits(planes):
    """PackBits is applied per row, and each channel carries a row-length table first.

    Getting this wrong is the classic way to produce a PSD that looks right and is not: the row table
    comes before the data for every channel, not once for the whole plane.
    """
    header = bytearray()
    data = bytearray()
    for plane in planes:
        rows = [_rle_encode_plane(np.ascontiguousarray(plane[y:y + 1, :])) for y in range(plane.shape[0])]
        header += b"".join(struct.pack(">H", len(row)) for row in rows)
        data += b"".join(rows)
    return bytes(header) + bytes(data)


class Layer:
    def __init__(self, name, left, top, pixels, opacity=255, blend="Normal", mask=None, visible=True):
        self.name = name
        self.left = left
        self.top = top
        self.pixels = pixels  # float RGBA in 0..1, shape (h, w)
        self.opacity = opacity
        self.blend = blend
        self.mask = mask  # uint8 grayscale, shape (h, w) or None
        self.visible = visible


def _layer_record(layer: Layer, channel_lengths):
    height, width = layer.pixels.shape[:2]
    rect = struct.pack(">iiii", layer.top, layer.left, layer.top + height, layer.left + width)
    keys = [0, 1, 2, -1]  # R, G, B, alpha
    if layer.mask is not None:
        keys.append(-2)
    record = bytearray()
    record += rect
    record += struct.pack(">H", len(keys))
    for key, length in zip(keys, channel_lengths):
        # The channel length covers the compression tag and the data.
        record += struct.pack(">hI", key, length)
    record += b"8BIM" + BLEND_KEYS.get(layer.blend, b"norm")
    record += struct.pack(">BB", layer.opacity, 0)
    flags = 0x08 if layer.visible else 0x02  # bit 1 = hidden, bit 3 = "useful data" (opaque)
    record += struct.pack(">B", flags)
    record += struct.pack(">B", 0)  # filler
    extra = bytearray()
    if layer.mask is not None:
        # A mask lives in two places: its pixels as a channel with id -2, and its rectangle and flags
        # here. Photoshop writes both, and a reader that follows the specification expects both.
        mask_height, mask_width = layer.mask.shape[:2]
        mask_block = struct.pack(">iiii", layer.top, layer.left, layer.top + mask_height,
                                 layer.left + mask_width)
        mask_block += struct.pack(">BBH", 0, 0, 0)  # default colour, flags, padding
        extra += struct.pack(">I", len(mask_block)) + mask_block
    else:
        extra += struct.pack(">I", 0)
    extra += struct.pack(">I", 0)  # blending ranges
    extra += _pascal_name(layer.name)
    record += struct.pack(">I", len(extra)) + extra
    return bytes(record)


def _channel_blobs(layer: Layer, compression=1):
    """One blob per channel, in the order the record lists them: R, G, B, A [, mask]."""
    alpha = np.clip(layer.pixels[..., 3] * 255.0, 0, 255).round().astype(np.uint8)
    planes = [np.clip(layer.pixels[..., index] * 255.0, 0, 255).round().astype(np.uint8)
              for index in range(3)]
    planes.append(alpha)
    if layer.mask is not None:
        planes.append(layer.mask.astype(np.uint8))
    blobs = []
    for plane in planes:
        if compression == 1:
            blobs.append(struct.pack(">H", 1) + _pack_bits([plane]))
        else:
            blobs.append(struct.pack(">H", 0) + plane.tobytes())
    return blobs


def _composite(document_layers, width, height):
    """An independent composite of the layers, in straight alpha, over transparency."""
    canvas = np.zeros((height, width, 4), dtype=np.float64)
    for layer in document_layers:
        if not layer.visible:
            continue
        h, w = layer.pixels.shape[:2]
        x0, y0 = max(0, layer.left), max(0, layer.top)
        x1, y1 = min(width, layer.left + w), min(height, layer.top + h)
        if x0 >= x1 or y0 >= y1:
            continue
        src = layer.pixels[y0 - layer.top:y1 - layer.top, x0 - layer.left:x1 - layer.left]
        alpha = src[..., 3] * (layer.opacity / 255.0)
        mask = None
        if layer.mask is not None:
            mask = layer.mask[y0 - layer.top:y1 - layer.top, x0 - layer.left:x1 - layer.left] / 255.0
            alpha = alpha * mask
        dst = canvas[y0:y1, x0:x1]
        for channel in range(3):
            cs = src[..., channel]
            cb = dst[..., channel]
            a = alpha
            if layer.blend == "Multiply":
                blended = cb * cs
            elif layer.blend == "Screen":
                blended = 1.0 - (1.0 - cb) * (1.0 - cs)
            elif layer.blend == "Darken":
                blended = np.minimum(cb, cs)
            elif layer.blend == "Lighten":
                blended = np.maximum(cb, cs)
            else:
                blended = cs
            out_a = a + dst[..., 3] * (1.0 - a)
            numerator = blended * a + cb * dst[..., 3] * (1.0 - a)
            dst[..., channel] = np.where(out_a > 0, numerator / np.maximum(out_a, 1e-9), 0.0)
        dst[..., 3] = alpha + dst[..., 3] * (1.0 - alpha)
    return canvas


def write_psd(path, width, height, layers, color_mode=3, depth=8, compression=1, channels=3):
    """Writes a layered PSD. color_mode 3 = RGB, 1 = grayscale."""
    body = bytearray()
    body += b"8BPS"
    body += struct.pack(">H", 1)  # version 1
    body += b"\x00" * 6
    body += struct.pack(">HIIHH", channels, height, width, depth, color_mode)
    body += struct.pack(">I", 0)  # colour mode data
    body += struct.pack(">I", 0)  # image resources
    body += struct.pack(">I", 0)  # layer and mask information length (patched below)
    layer_info_start = len(body)
    layer_records = bytearray()
    channel_blobs = bytearray()
    for layer in layers:
        blobs = _channel_blobs(layer, compression=compression)
        layer_records += _layer_record(layer, [len(blob) for blob in blobs])
        channel_blobs += b"".join(blobs)
    layer_info = bytearray()
    layer_info += struct.pack(">H", len(layers))
    layer_info += layer_records
    layer_info += channel_blobs
    if len(layer_info) % 2:
        layer_info += b"\x00"
    body += struct.pack(">I", len(layer_info))
    body += layer_info
    if len(layer_info) % 4:
        body += b"\x00" * (4 - len(layer_info) % 4)
    body += struct.pack(">I", 0)  # global layer mask info
    struct.pack_into(">I", body, layer_info_start - 4, len(layer_info))

    composite = _composite(layers, width, height)
    # The merged image is stored as planar channels, alpha last when present.
    planes = [np.clip(composite[..., index] * 255.0, 0, 255).round().astype(np.uint8) for index in range(3)]
    if channels == 4:
        planes.append(np.clip(composite[..., 3] * 255.0, 0, 255).round().astype(np.uint8))
    body += struct.pack(">H", compression)
    if compression == 1:
        body += _pack_bits(planes)
    else:
        body += b"".join(np.ascontiguousarray(plane).tobytes() for plane in planes)
    with open(path, "wb") as handle:
        handle.write(bytes(body))
    return composite
