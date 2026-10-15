#!/usr/bin/env python3
"""Convert a PostScript or PDF job into TSPL for the Coibeu WKDY-81X."""

import argparse
import os
import shutil
import subprocess
import sys

DPI = 203


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--gap", type=float, default=2.0)
    args, _unknown = parser.parse_known_args(argv)
    if args.gap < 0:
        args.gap = 0.0
    return args


def iter_pbm_pages(data):
    """Yield width, height and packed bitmap rows from Ghostscript pbmraw."""
    index = 0
    length = len(data)
    while index < length:
        while index < length and data[index] in b" \t\r\n":
            index += 1
        if index >= length:
            return
        if data[index:index + 2] != b"P4":
            raise RuntimeError(f"unexpected PBM header at offset {index}")
        index += 2
        tokens = []
        while len(tokens) < 2:
            while index < length and data[index] in b" \t\r\n":
                index += 1
            if index < length and data[index] == ord("#"):
                while index < length and data[index] not in b"\r\n":
                    index += 1
                continue
            start = index
            while index < length and data[index] not in b" \t\r\n":
                index += 1
            if start == index:
                raise RuntimeError("truncated PBM header")
            tokens.append(int(data[start:index]))
        if index < length and data[index] in b" \t\r\n":
            index += 1
        width, height = tokens
        row_bytes = (width + 7) // 8
        nbytes = row_bytes * height
        bitmap = data[index:index + nbytes]
        if len(bitmap) != nbytes:
            raise RuntimeError("truncated PBM bitmap")
        index += nbytes
        yield width, height, bitmap


def invert_bitmap(bitmap):
    # The WKDY-81X burns a cleared bit. PBM uses 1 for black, so flip every byte.
    return bytes(byte ^ 0xFF for byte in bitmap)


def page_to_tspl(width, height, bitmap, gap_mm):
    width_mm = width / DPI * 25.4
    height_mm = height / DPI * 25.4
    row_bytes = (width + 7) // 8
    header = (
        f"SIZE {width_mm:.2f} mm, {height_mm:.2f} mm\r\n"
        f"GAP {gap_mm:.2f} mm, 0 mm\r\n"
        "DENSITY 8\r\n"
        "DIRECTION 1\r\n"
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


def render_pbm(document):
    command = [
        ghostscript_executable(),
        "-q",
        "-dSAFER",
        "-dBATCH",
        "-dNOPAUSE",
        "-sDEVICE=pbmraw",
        "-r203",
        "-sOutputFile=-",
        "-c",
        "{0.5 gt {1} {0} ifelse} settransfer",
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
    rendered = render_pbm(document)
    output = bytearray()
    for width, height, bitmap in iter_pbm_pages(rendered):
        output += page_to_tspl(width, height, bitmap, args.gap)
    sys.stdout.buffer.write(output)


if __name__ == "__main__":
    main()
