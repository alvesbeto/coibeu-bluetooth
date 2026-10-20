#!/usr/bin/env python3
"""Convert a PostScript or PDF job into TSPL for the Coibeu WKDY-81X."""

import argparse
import os
import shutil
import subprocess
import sys

DPI = 203
# Channels at or above this stay unburned paper. The J&T red (255, 0, 26)
# becomes gray 129 in Ghostscript, so a 50% cut leaves it white on the label.
PAPER_LEVEL = 250


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--gap", type=float, default=3.0)
    args, _unknown = parser.parse_known_args(argv)
    if args.gap < 0:
        args.gap = 0.0
    return args


def _next_token(data, index):
    length = len(data)
    while index < length and data[index] in b" \t\r\n":
        index += 1
    if index < length and data[index] == ord("#"):
        while index < length and data[index] not in b"\r\n":
            index += 1
        return _next_token(data, index)
    start = index
    while index < length and data[index] not in b" \t\r\n":
        index += 1
    if start == index:
        raise RuntimeError("truncated PPM header")
    return data[start:index], index


def iter_ppm_pages(data):
    """Yield width, height and packed RGB from Ghostscript ppmraw."""
    index = 0
    length = len(data)
    while index < length:
        while index < length and data[index] in b" \t\r\n":
            index += 1
        if index >= length:
            return
        if data[index:index + 2] != b"P6":
            raise RuntimeError(f"unexpected PPM header at offset {index}")
        index += 2
        width_token, index = _next_token(data, index)
        height_token, index = _next_token(data, index)
        max_token, index = _next_token(data, index)
        width = int(width_token)
        height = int(height_token)
        if int(max_token) != 255:
            raise RuntimeError("unsupported PPM max value")
        if index < length and data[index] in b" \t\r\n":
            index += 1
        nbytes = width * height * 3
        rgb = data[index:index + nbytes]
        if len(rgb) != nbytes:
            raise RuntimeError("truncated PPM bitmap")
        index += nbytes
        yield width, height, rgb


def pack_ink(width, height, rgb):
    """Pack a 1-bit page where 1 means burn. Near-white pixels stay paper."""
    row_bytes = (width + 7) // 8
    bitmap = bytearray(row_bytes * height)
    pixel = 0
    for y in range(height):
        row = y * row_bytes
        for x in range(width):
            red = rgb[pixel]
            green = rgb[pixel + 1]
            blue = rgb[pixel + 2]
            pixel += 3
            if red >= PAPER_LEVEL and green >= PAPER_LEVEL and blue >= PAPER_LEVEL:
                continue
            bitmap[row + (x // 8)] |= 0x80 >> (x % 8)
    return bytes(bitmap)


def invert_bitmap(bitmap):
    # The WKDY-81X burns a cleared bit. PBM uses 1 for black, so flip every byte.
    return bytes(byte ^ 0xFF for byte in bitmap)


def page_to_tspl(width, height, bitmap, gap_mm):
    # LABELCORE sends SIZE, DIRECTION, GAP, DENSITY, SPEED, SET TEAR, CLS, BITMAP.
    # Its defaults are density 8, speed index 14 (TSPL SPEED 8) and a 3 mm gap.
    # A stored gap of 0 mm is rewritten to 3 mm for gapped stock.
    # DIRECTION stays 1 because this unit was printed and checked with that value.
    # The DLL also inverts each bitmap byte before BITMAP mode 0.
    width_mm = width / DPI * 25.4
    height_mm = height / DPI * 25.4
    row_bytes = (width + 7) // 8
    header = (
        f"SIZE {width_mm:.2f} mm, {height_mm:.2f} mm\r\n"
        "DIRECTION 1\r\n"
        f"GAP {gap_mm:.2f} mm, 0 mm\r\n"
        "DENSITY 8\r\n"
        "SPEED 8\r\n"
        "SET TEAR ON\r\n"
        "CLS\r\n"
        f"BITMAP 0,0,{row_bytes},{height},0,"
    ).encode("ascii")
    return header + invert_bitmap(bitmap) + b"\r\nPRINT 1,1\r\n"


def ghostscript_executable():
    # CUPS on Linux finds gs on PATH. Homebrew on macOS installs it outside that PATH.
    override = os.environ.get("COIBEU_GS", "").strip()
    candidates = [override, "gs", "/opt/homebrew/bin/gs", "/usr/local/bin/gs"]
    for candidate in candidates:
        if not candidate:
            continue
        if os.path.isabs(candidate) and os.access(candidate, os.X_OK):
            return candidate
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    raise RuntimeError("ghostscript (gs) not found")


def render_ppm(document):
    command = [
        ghostscript_executable(),
        "-q",
        "-dSAFER",
        "-dBATCH",
        "-dNOPAUSE",
        "-dTextAlphaBits=1",
        "-dGraphicsAlphaBits=1",
        "-sDEVICE=ppmraw",
        "-r203",
        "-sOutputFile=-",
        "-f",
        "-",
    ]
    if document.startswith(b"%PDF"):
        command.insert(command.index("-sOutputFile=-"), "-dPDFFitPage")
    result = subprocess.run(
        command,
        input=document,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.buffer.write(result.stderr)
        raise RuntimeError(f"ghostscript exited {result.returncode}")
    return result.stdout


def main():
    args = parse_args(sys.argv[1:])
    document = sys.stdin.buffer.read()
    if not document:
        return
    rendered = render_ppm(document)
    output = bytearray()
    for width, height, rgb in iter_ppm_pages(rendered):
        output += page_to_tspl(width, height, pack_ink(width, height, rgb), args.gap)
    sys.stdout.buffer.write(output)


if __name__ == "__main__":
    main()
