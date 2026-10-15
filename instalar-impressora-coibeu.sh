#!/bin/bash
# Reinstall the Coibeu WKDY-81X thermal label printer over Bluetooth RFCOMM.
# The printer advertises classic Serial Port Profile plus BLE. CUPS has no
# built-in driver for that combination, so this script installs a user-space
# RFCOMM bridge and a TSPL filter behind a local JetDirect socket.
# Linux uses BlueZ and systemd. macOS uses IOBluetooth and launchd.

set -euo pipefail

OS_NAME="$(uname -s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="Coibeu-WKDY-81X"
LIB_DIR="${HOME}/.local/lib/coibeu"
CONFIG_DIR="${HOME}/.config/coibeu"
CONFIG="${CONFIG_DIR}/printer.conf"
PPD="${LIB_DIR}/coibeu-wkdy-81x.ppd"
SERVICE_NAME="coibeu-rfcomm.service"
SERVICE_PATH="${HOME}/.config/systemd/user/${SERVICE_NAME}"
LAUNCH_LABEL="com.coibeu.rfcomm"
PORT="9101"
CHANNEL="1"
PRINTER_NAME="BlueTooth Printer"
# This unit, used only when a live scan and printer.conf are both empty.
KNOWN_MAC="66:32:1A:63:16:C7"

log() {
  printf '%s\n' "$*" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Comando ausente: $1"
    exit 1
  fi
}

write_helpers() {
  mkdir -p "${LIB_DIR}" "${CONFIG_DIR}" "$(dirname "${SERVICE_PATH}")"

  cat > "${LIB_DIR}/ps_to_tspl.py" << 'PY'
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
PY

  cat > "${LIB_DIR}/rfcomm_bridge.py" << 'PY'
#!/usr/bin/env python3
"""Accept raw TSPL on localhost and forward it to the printer RFCOMM channel."""

import configparser
import os
import socket
import subprocess
import sys
import time

CONFIG_PATH = os.environ.get(
    "COIBEU_CONFIG",
    os.path.expanduser("~/.config/coibeu/printer.conf"),
)
MAX_JOB_BYTES = 8 * 1024 * 1024


def log(message):
    print(message, file=sys.stderr, flush=True)


def load_settings():
    parser = configparser.ConfigParser()
    # The config file is a flat KEY=value list, not an INI section.
    with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
        parser.read_string("[printer]\n" + handle.read())
    section = parser["printer"]
    return {
        "mac": section.get("MAC", "").strip(),
        "channel": section.getint("CHANNEL", fallback=1),
        "port": section.getint("PORT", fallback=9101),
    }


def read_job(connection):
    chunks = []
    total = 0
    while total < MAX_JOB_BYTES:
        try:
            piece = connection.recv(65536)
        except socket.timeout:
            break
        if not piece:
            break
        chunks.append(piece)
        total += len(piece)
    return b"".join(chunks)


def open_rfcomm(mac, channel):
    last_error = None
    for attempt in range(1, 9):
        link = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        link.settimeout(20)
        try:
            link.connect((mac, channel))
            return link
        except OSError as error:
            last_error = error
            log(f"RFCOMM attempt {attempt} failed: {error}")
            try:
                link.close()
            except OSError:
                pass
            time.sleep(1)
    raise last_error


def wait_until_ready(process):
    while True:
        line = process.stderr.readline()
        if not line:
            code = process.wait()
            raise OSError(f"rfcomm helper exited {code}")
        text = line.decode("utf-8", "replace").rstrip()
        if text == "READY":
            return
        if text:
            log(text)


def deliver_with_helper(helper, mac, channel, connection):
    # The helper opens RFCOMM and prints READY before reading stdin.
    process = subprocess.Popen(
        [helper, "send", mac, str(channel)],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        wait_until_ready(process)
    except OSError:
        process.kill()
        process.wait()
        raise
    payload = read_job(connection)
    log(f"forwarding {len(payload)} bytes")
    process.stdin.write(payload)
    process.stdin.close()
    error_text = process.stderr.read().decode("utf-8", "replace").rstrip()
    if error_text:
        log(error_text)
    code = process.wait()
    if code != 0:
        raise OSError(f"rfcomm helper exited {code}")


def deliver_with_socket(mac, channel, connection):
    link = open_rfcomm(mac, channel)
    try:
        payload = read_job(connection)
        log(f"forwarding {len(payload)} bytes")
        if payload:
            link.sendall(payload)
            time.sleep(0.3)
    finally:
        link.close()


def deliver(mac, channel, connection):
    helper = os.environ.get("COIBEU_RFCOMM", "").strip()
    if helper:
        deliver_with_helper(helper, mac, channel, connection)
        return
    deliver_with_socket(mac, channel, connection)


def serve():
    settings = load_settings()
    if not settings["mac"]:
        raise RuntimeError(f"MAC ausente em {CONFIG_PATH}")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", settings["port"]))
    server.listen(1)
    log(
        f"bridge listening on 127.0.0.1:{settings['port']} "
        f"for {settings['mac']} channel {settings['channel']}"
    )
    while True:
        connection, _address = server.accept()
        connection.settimeout(60)
        try:
            # Open the printer before draining the socket so a failed
            # Bluetooth connect still surfaces as a CUPS backend error.
            current = load_settings()
            deliver(current["mac"], current["channel"], connection)
            connection.close()
        except Exception as error:
            log(f"job failed: {error}")
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()


if __name__ == "__main__":
    serve()
PY

  chmod 755 "${LIB_DIR}/ps_to_tspl.py" "${LIB_DIR}/rfcomm_bridge.py"
}

write_ppd() {
  local mode="linux"
  local raster_filter="${LIB_DIR}/rastertotspl-coibeu"
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    mode="macos"
  fi
  python3 - "${PPD}" "${LIB_DIR}/ps_to_tspl.py" "${mode}" "${raster_filter}" << 'PY'
import sys

destination, converter, mode, raster_filter = sys.argv[1:5]
sizes = [
    (100, 150, "w100h150", "100 x 150 mm", True),
    (100, 100, "w100h100", "100 x 100 mm", False),
    (100, 50, "w100h50", "100 x 50 mm", False),
    (80, 50, "w80h50", "80 x 50 mm", False),
    (60, 40, "w60h40", "60 x 40 mm", False),
    (50, 30, "w50h30", "50 x 30 mm", False),
    (40, 30, "w40h30", "40 x 30 mm", False),
    (40, 20, "w40h20", "40 x 20 mm", False),
]

def pixels(mm):
    return round(mm / 25.4 * 203)

def points(px):
    return px / 203 * 72

lines = [
    '*PPD-Adobe: "4.3"',
    '*FormatVersion: "4.3"',
    '*FileVersion: "1.0"',
    '*LanguageVersion: English',
    '*LanguageEncoding: ISOLatin1',
    '*PCFileName: "COIBEU.PPD"',
    '*Manufacturer: "Coibeu"',
    '*Product: "(WKDY-81X)"',
    '*ModelName: "Coibeu WKDY-81X"',
    '*ShortNickName: "Coibeu WKDY-81X"',
    '*NickName: "Coibeu WKDY-81X Bluetooth"',
    '*PSVersion: "(3010.000) 0"',
    '*LanguageLevel: "3"',
    '*ColorDevice: False',
    '*DefaultColorSpace: Gray',
    '*FileSystem: False',
    '*Throughput: "8"',
    '*LandscapeOrientation: Plus90',
    '*TTRasterizer: Type42',
    '*1284DeviceID: "MFG:Coibeu;MDL:WKDY-81X;CMD:TSPL;"',
    '*cupsVersion: 2.4',
    '*cupsSNMPSupplies: False',
    '*cupsManualCopies: True',
    '*cupsModelNumber: 1',
]
if mode == "macos":
    # macOS already turns PDF into CUPS raster. The filter must live in the
    # CUPS ServerBin and be owned by root, or cupsd refuses to run it.
    lines.append('*cupsFilter: "application/vnd.cups-raster 0 rastertotspl-coibeu"')
else:
    lines += [
        '*cupsFilter: "application/vnd.cups-pdf 100 foomatic-rip"',
        '*cupsFilter: "application/vnd.cups-postscript 100 foomatic-rip"',
        f'*FoomaticRIPCommandLine: "{converter} %A"',
        '*FoomaticIDs: "Coibeu-WKDY-81X"',
    ]
lines += [
    '*OpenUI *PageSize/Tamanho da etiqueta: PickOne',
    '*OrderDependency: 10 AnySetup *PageSize',
    '*DefaultPageSize: w100h150',
]
for width_mm, height_mm, key, label, _default in sizes:
    width_pt = points(pixels(width_mm))
    height_pt = points(pixels(height_mm))
    lines.append(
        f'*PageSize {key}/{label}: "<</PageSize[{width_pt:.2f} {height_pt:.2f}]>>setpagedevice"'
    )
lines += [
    '*CloseUI: *PageSize',
    '*OpenUI *PageRegion/Regiao: PickOne',
    '*OrderDependency: 10 AnySetup *PageRegion',
    '*DefaultPageRegion: w100h150',
]
for width_mm, height_mm, key, label, _default in sizes:
    width_pt = points(pixels(width_mm))
    height_pt = points(pixels(height_mm))
    lines.append(
        f'*PageRegion {key}/{label}: "<</PageSize[{width_pt:.2f} {height_pt:.2f}]>>setpagedevice"'
    )
lines.append('*CloseUI: *PageRegion')
for width_mm, height_mm, key, _label, is_default in sizes:
    width_pt = points(pixels(width_mm))
    height_pt = points(pixels(height_mm))
    if is_default:
        lines.append(f'*DefaultImageableArea: {key}')
        lines.append(f'*DefaultPaperDimension: {key}')
    lines.append(f'*ImageableArea {key}: "0.00 0.00 {width_pt:.2f} {height_pt:.2f}"')
    lines.append(f'*PaperDimension {key}: "{width_pt:.2f} {height_pt:.2f}"')
lines += [
    '*OpenUI *Resolution/Resolucao: PickOne',
    '*OrderDependency: 20 AnySetup *Resolution',
    '*DefaultResolution: 203dpi',
    '*Resolution 203dpi/203 DPI: "<</HWResolution[203 203]>>setpagedevice"',
    '*CloseUI: *Resolution',
    '*OpenUI *ColorModel/Cor: PickOne',
    '*OrderDependency: 20 AnySetup *ColorModel',
    '*DefaultColorModel: Gray',
    '*ColorModel Gray/Escala de cinza: "<</cupsColorSpace 3/cupsColorOrder 0/cupsBitsPerColor 1>>setpagedevice"',
    '*CloseUI: *ColorModel',
]
if mode == "macos":
    lines += [
        '*OpenUI *GapMm/Espaco entre etiquetas: PickOne',
        '*OrderDependency: 100 AnySetup *GapMm',
        '*DefaultGapMm: Gap2',
        '*GapMm Gap2/2 mm: ""',
        '*GapMm Gap3/3 mm: ""',
        '*GapMm Gap0/Continuo: ""',
        '*CloseUI: *GapMm',
    ]
else:
    lines += [
        '*OpenUI *GapMm/Espaco entre etiquetas: PickOne',
        '*FoomaticRIPOption GapMm: enum CmdLine A',
        '*OrderDependency: 100 AnySetup *GapMm',
        '*DefaultGapMm: Gap2',
        '*GapMm Gap2/2 mm: "%% FoomaticRIPOptionSetting: GapMm=2"',
        '*GapMm Gap3/3 mm: "%% FoomaticRIPOptionSetting: GapMm=3"',
        '*GapMm Gap0/Continuo: "%% FoomaticRIPOptionSetting: GapMm=0"',
        '*FoomaticRIPOptionPrototype GapMm: " --gap %s"',
        '*CloseUI: *GapMm',
    ]
lines += [
    '*DefaultFont: Courier',
    '*Font Courier: Standard "(001.006S)" Standard ROM',
]
with open(destination, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
}

grant_filter_access() {
  # cupsd runs filters as user lp, which cannot traverse a 750 home directory.
  setfacl -m u:lp:--x "${HOME}"
  setfacl -m u:lp:--x "${HOME}/.local"
  setfacl -m u:lp:--x "${HOME}/.local/lib"
  setfacl -m u:lp:r-x "${LIB_DIR}"
  setfacl -m d:u:lp:r-x "${LIB_DIR}"
  setfacl -m u:lp:r-x "${LIB_DIR}/ps_to_tspl.py" "${LIB_DIR}/rfcomm_bridge.py"
}

known_mac() {
  if [[ -f "${CONFIG}" ]]; then
    awk -F= '/^MAC=/{print $2; exit}' "${CONFIG}"
  fi
}

device_present() {
  local mac="$1"
  bluetoothctl info "${mac}" 2>/dev/null | grep -q "Name: ${PRINTER_NAME}"
}

discover_mac_macos() {
  local mac saved
  saved="$(known_mac || true)"
  mac="$("${LIB_DIR}/coibeu-rfcomm" discover || true)"
  mac="${mac%%$'\n'*}"
  if [[ -n "${mac}" ]]; then
    printf '%s\n' "${mac}"
    return
  fi
  if [[ -n "${saved}" ]]; then
    log "Impressora fora do alcance. Reutilizando ${saved}."
    printf '%s\n' "${saved}"
    return
  fi
  if [[ -n "${KNOWN_MAC}" ]]; then
    log "Impressora fora do alcance. Reutilizando ${KNOWN_MAC}."
    printf '%s\n' "${KNOWN_MAC}"
    return
  fi
  log "Impressora Bluetooth nao encontrada. Ligue a WKDY-81X e execute de novo."
  exit 1
}

discover_mac() {
  local mac saved
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    discover_mac_macos
    return
  fi
  saved="$(known_mac || true)"
  bluetoothctl power on >/dev/null
  mac="$(bluetoothctl devices | awk -v name="${PRINTER_NAME}" '$0 ~ name {print $2; exit}')"
  if [[ -n "${mac}" ]]; then
    printf '%s\n' "${mac}"
    return
  fi
  log "Procurando ${PRINTER_NAME}..."
  bluetoothctl --timeout 20 scan on >/dev/null || true
  mac="$(bluetoothctl devices | awk -v name="${PRINTER_NAME}" '$0 ~ name {print $2; exit}')"
  if [[ -n "${mac}" ]]; then
    printf '%s\n' "${mac}"
    return
  fi
  if [[ -n "${saved}" ]]; then
    log "Impressora fora do alcance. Reutilizando ${saved}."
    printf '%s\n' "${saved}"
    return
  fi
  log "Impressora Bluetooth nao encontrada. Ligue a WKDY-81X e execute de novo."
  exit 1
}

write_config() {
  local mac="$1"
  cat > "${CONFIG}" << EOF
MAC=${mac}
CHANNEL=${CHANNEL}
PORT=${PORT}
EOF
  chmod 644 "${CONFIG}"
}

copy_source() {
  local name="$1"
  if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    cp "${SCRIPT_DIR}/${name}" "${LIB_DIR}/${name}"
    return
  fi
  if [[ ! -f "${LIB_DIR}/${name}" ]]; then
    log "Arquivo ausente: ${name}"
    exit 1
  fi
}

compile_macos() {
  copy_source coibeu-rfcomm.swift
  copy_source rastertotspl.c
  swiftc -O -framework Foundation -framework IOBluetooth \
    -o "${LIB_DIR}/coibeu-rfcomm" "${LIB_DIR}/coibeu-rfcomm.swift"
  codesign --force --sign - "${LIB_DIR}/coibeu-rfcomm"
  clang -O2 -Wall -Wextra -o "${LIB_DIR}/rastertotspl-coibeu" "${LIB_DIR}/rastertotspl.c" -lcups
  chmod 755 "${LIB_DIR}/coibeu-rfcomm" "${LIB_DIR}/rastertotspl-coibeu"
  install_trusted_filter
}

install_trusted_filter() {
  local src="${LIB_DIR}/rastertotspl-coibeu"
  local dest="/usr/libexec/cups/filter/rastertotspl-coibeu"
  # cupsd rejects a filter owned by the user (cups-insecure-filter).
  osascript << EOF
do shell script "/usr/bin/install -m 755 -o root -g wheel ${src} ${dest}" with administrator privileges
EOF
}

install_launch_agent() {
  local plist="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
  local domain="gui/$(id -u)"
  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
  cat > "${plist}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${LIB_DIR}/rfcomm_bridge.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>COIBEU_CONFIG</key>
    <string>${CONFIG}</string>
    <key>COIBEU_RFCOMM</key>
    <string>${LIB_DIR}/coibeu-rfcomm</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/coibeu-rfcomm.log</string>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/coibeu-rfcomm.log</string>
</dict>
</plist>
EOF
  launchctl bootout "${domain}/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "${domain}" "${plist}"
  launchctl enable "${domain}/${LAUNCH_LABEL}"
  launchctl kickstart -k "${domain}/${LAUNCH_LABEL}"
}

publish_command() {
  local target="${HOME}/.local/bin/instalar-impressora-coibeu.sh"
  mkdir -p "${HOME}/.local/bin"
  if [[ "${SCRIPT_DIR}/instalar-impressora-coibeu.sh" != "${target}" ]]; then
    cp "${SCRIPT_DIR}/instalar-impressora-coibeu.sh" "${target}"
    chmod 755 "${target}"
  fi
  if [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then
    ln -sfn "${target}" /opt/homebrew/bin/instalar-impressora-coibeu.sh
  fi
}

install_service() {
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    install_launch_agent
    return
  fi
  cat > "${SERVICE_PATH}" << EOF
[Unit]
Description=Coibeu WKDY-81X Bluetooth bridge for CUPS
After=bluetooth.target

[Service]
ExecStart=/usr/bin/python3 ${LIB_DIR}/rfcomm_bridge.py
Environment=COIBEU_CONFIG=${CONFIG}
Environment=PYTHONUNBUFFERED=1
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}"
  systemctl --user restart "${SERVICE_NAME}"
}

install_queue() {
  lpadmin -p "${QUEUE}" -E \
    -v "socket://127.0.0.1:${PORT}" \
    -P "${PPD}" \
    -D "Coibeu WKDY-81X" \
    -L "Bluetooth" \
    -o printer-is-shared=false \
    -o printer-error-policy=retry-job
  lpadmin -d "${QUEUE}"
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    # A per-user lpoptions file overrides the system default on macOS.
    lpoptions -d "${QUEUE}"
  fi
  cupsenable "${QUEUE}"
  cupsaccept "${QUEUE}"
}

print_test() {
  local page
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    print_test_pdf
    return
  fi
  page="$(mktemp /tmp/coibeu-test-XXXXXX.ps)"
  python3 - "${page}" << 'PY'
import sys
width_px = round(40 / 25.4 * 203)
height_px = round(30 / 25.4 * 203)
width_pt = width_px / 203 * 72
height_pt = height_px / 203 * 72
content = f"""%!PS-Adobe-3.0
<< /PageSize [{width_pt:.2f} {height_pt:.2f}] >> setpagedevice
/Courier findfont 14 scalefont setfont
8 40 moveto (WKDY-81X CUPS) show
showpage
"""
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(content)
PY
  lp -d "${QUEUE}" -o media=w40h30 -o GapMm=Gap2 -t "coibeu-teste" "${page}"
  rm -f "${page}"
}

print_test_pdf() {
  local page
  page="$(mktemp /tmp/coibeu-test-XXXXXX.pdf)"
  python3 - "${page}" << 'PY'
import sys
width = 40 / 25.4 * 72
height = 30 / 25.4 * 72
stream = b"BT /F1 12 Tf 8 36 Td (WKDY-81X CUPS) Tj ET\n"
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
    (
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:.2f} {height:.2f}] "
        f"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
    ).encode("ascii"),
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
]
chunks = [b"%PDF-1.4\n"]
offsets = [0]
for number, body in enumerate(objects, start=1):
    offsets.append(sum(len(chunk) for chunk in chunks))
    chunks.append(f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n")
xref = sum(len(chunk) for chunk in chunks)
chunks.append(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
chunks.append(b"0000000000 65535 f \n")
for offset in offsets[1:]:
    chunks.append(f"{offset:010d} 00000 n \n".encode("ascii"))
chunks.append(
    (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n"
    ).encode("ascii")
)
with open(sys.argv[1], "wb") as handle:
    handle.write(b"".join(chunks))
PY
  lp -d "${QUEUE}" -o PageSize=w40h30 -o media=w40h30 -o GapMm=Gap2 -t "coibeu-teste" "${page}"
  rm -f "${page}"
}

main() {
  require_cmd python3
  require_cmd lpadmin
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    require_cmd swiftc
    require_cmd clang
    require_cmd launchctl
  else
    require_cmd bluetoothctl
    require_cmd gs
    require_cmd setfacl
    require_cmd systemctl
  fi

  write_helpers
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    compile_macos
  fi

  local mac
  mac="$(discover_mac)"
  log "Impressora: ${mac}"
  if [[ "${OS_NAME}" != "Darwin" ]]; then
    bluetoothctl trust "${mac}" >/dev/null || true
    bluetoothctl disconnect "${mac}" >/dev/null || true
  fi

  write_ppd
  if [[ "${OS_NAME}" != "Darwin" ]]; then
    grant_filter_access
  fi
  write_config "${mac}"
  install_service
  install_queue
  if [[ "${OS_NAME}" == "Darwin" ]]; then
    publish_command
  fi

  log "Fila ${QUEUE} pronta em socket://127.0.0.1:${PORT}"
  if [[ "${1:-}" == "testar" ]]; then
    print_test
    log "Etiqueta de teste enviada para ${QUEUE}."
  fi
}

main "$@"
