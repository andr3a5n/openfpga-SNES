#!/usr/bin/env python3
"""MSU-1 phase 0 probe tooling.

  msu_probe.py files OUTDIR      Write the test file set (ROM, .msu, .pcm)
  msu_probe.py decode LOGFILE    Print a report from the probe's log file
  msu_probe.py rtl               Regenerate target/pocket/msu/msu_probe_rom.sv

The log layout and result indices must match target/pocket/msu/msu_probe.sv.
"""

import argparse
import array
import os
import struct
import sys

CLOCK_HZ = 74_250_000

ROM_NAME = "msuprobe"
PCM_SIZE = 16 * 1024 * 1024 + 1236  # 16 MiB + 309 samples, not 4 KB aligned
MSU_SIZE = 1024 * 1024 + 4
DIRECTORY_TRACKS = 100  # tracks 2-100 are tiny, so the folder looks like a real pack

TAG_PCM = 1
TAG_MSU = 2

# ----------------------------------------------------------------------------
# Log layout (32-bit little-endian words)

L_RESULTS = 0x002
L_SNAP = {"boot": 0x048, "after .msu open": 0x088, "after slot 20 open": 0x0C8,
          "after slot 22 open": 0x108, "end": 0x148}
L_RESP_ROM = 0x188
L_RESP_EMPTY = 0x1C8
L_RESP_MSU = 0x208
L_PARAM_MSU = 0x248
L_PARAM_PCM = 0x290
L_TP_READS = 0x2D8
L_RND = 0x328
L_ALT = 0x338
L_SIZE = 0x378

# (index, 3-letter screen label, description)
RESULTS = [
    (0, "STA", "status: [31] done [30] aborted [7:0] last step"),
    (1, "TIM", "probe run time (x1024 cycles)"),
    (2, "BOT", "PLL lock to APF reset exit (cycles)"),
    (3, "FST", "reset exit to first command done (cycles)"),
    (4, "G0E", "0190 slot 0: [8] bridge_endian_little [2:0] result"),
    (5, "G0T", "0190 slot 0: cycles"),
    (6, "GEE", "0190 empty slot 20: result"),
    (7, "GET", "0190 empty slot 20: cycles"),
    (8, "OME", "0192 .msu into slot 21: result (0x80 = no path)"),
    (9, "OMT", "0192 .msu into slot 21: cycles"),
    (10, "G2E", "0190 slot 21 after open: result"),
    (11, "G2T", "0190 slot 21 after open: cycles"),
    (12, "O8E", "0192 -1.pcm into slot 20 (read-only): result"),
    (13, "O8T", "0192 -1.pcm into slot 20 (read-only): cycles"),
    (14, "O1E", "0192 -1.pcm into slot 22 (reloadable): result"),
    (15, "O1T", "0192 -1.pcm into slot 22 (reloadable): cycles"),
    (16, "MSE", "0192 -65535.pcm (missing): result"),
    (17, "MST", "0192 -65535.pcm (missing): cycles"),
    (18, "OCE", "0192 -100.pcm: result"),
    (19, "OCT", "0192 -100.pcm: cycles"),
    (20, "ROE", "0192 -1.pcm again into the read slot: result"),
    (21, "ROT", "0192 -1.pcm again into the read slot: cycles"),
    (22, "RSL", "read slot: [31] usable [15:0] slot id"),
    (23, "PMM", "pattern mismatches in all checked reads"),
    (24, "T4K", "512 KB in 4 KB reads: total cycles"),
    (25, "M4K", "4 KB reads: slowest read (cycles)"),
    (26, "T8K", "512 KB in 8 KB reads: total cycles"),
    (27, "M8K", "8 KB reads: slowest read"),
    (28, "T16", "512 KB in 16 KB reads: total cycles"),
    (29, "M16", "16 KB reads: slowest read"),
    (30, "T32", "512 KB in 32 KB reads: total cycles"),
    (31, "M32", "32 KB reads: slowest read"),
    (32, "T64", "512 KB in 64 KB reads: total cycles"),
    (33, "M64", "64 KB reads: slowest read"),
    (34, "TPE", "throughput reads with an error or short count"),
    (35, "RNT", "8 scattered 4 KB reads: total cycles"),
    (36, "RNM", "scattered reads: slowest"),
    (37, "ALT", "32 reads alternating .pcm/.msu: total cycles"),
    (38, "ALM", "alternating reads: slowest"),
    (39, "SZO", "size search: last 4 KB-aligned offset that read fine"),
    (40, "SZN", "size search: number of reads"),
    (41, "SZT", "size search: total cycles"),
    (42, "XRD", "4 KB read crossing EOF: [31:8] words [2:0] result"),
    (43, "CLA", "len FFFFFFFF from SZO+4K: [31:8] words [2:0] result"),
    (44, "CLB", "len FFFFFFFF from the estimated size: words, result"),
    (45, "CLC", "len FFFFFFFF from SZO: words, result"),
    (46, "FAR", "4 bytes at 0x7FFF0000: words, result"),
    (47, "D20", "datatable size for slot 20 at the end"),
    (48, None, "datatable size for slot 21 at the end"),
    (49, None, "datatable size for slot 22 at the end"),
    (50, None, "first raw bridge word received"),
    (51, None, "first pattern mismatch: file offset"),
    (52, None, "first pattern mismatch: data"),
    (53, None, ".msu path: [16] ok [8:0] length"),
    (54, None, "-1.pcm path: [16] ok [8:0] length"),
    (55, None, "bridge_endian_little"),
    (56, None, "datatable size for slot 20 at boot"),
    (57, None, "datatable size for slot 21 at boot"),
    (58, None, "datatable size for slot 22 at boot"),
    (59, None, "alternating reads with an error or short count"),
    (60, None, "scattered reads with an error or short count"),
    (61, None, "file size estimated from the clamped read"),
]

OPEN_RESULTS = {0: "ok", 1: "created", 2: "slot not defined", 3: "file not found",
                4: "malformed path", 5: "general error", 7: "timeout (no answer)"}
READ_RESULTS = {0: "ok", 1: "slot not defined", 2: "error or out of range",
                7: "timeout (no answer)"}
GETFILE_RESULTS = {0: "ok", 1: "slot not defined", 7: "timeout (no answer)"}

# ----------------------------------------------------------------------------
# Test files


def pattern_words(tag, start_word, count):
    base = (tag << 28) + start_word
    return array.array("I", range(base, base + count))


def write_pattern_file(path, tag, size, header=None):
    assert size % 4 == 0
    words = size // 4
    with open(path, "wb") as f:
        chunk = 1 << 20
        for start in range(0, words, chunk):
            data = pattern_words(tag, start, min(chunk, words - start))
            if sys.byteorder != "little":
                data.byteswap()
            raw = data.tobytes()
            if start == 0 and header:
                raw = header + raw[len(header):]
            f.write(raw)


def make_rom():
    """A 32 KB LoROM that turns the screen green, so a released SNES is visible."""
    rom = bytearray(b"\xFF" * 0x8000)
    code = bytes([
        0x78,              # SEI
        0x18,              # CLC
        0xFB,              # XCE          native mode
        0xE2, 0x20,        # SEP #$20     8-bit A
        0xA9, 0x80,        # LDA #$80
        0x8D, 0x00, 0x21,  # STA $2100    forced blank
        0x9C, 0x21, 0x21,  # STZ $2121    CGRAM address 0
        0xA9, 0xE0,        # LDA #$E0     BGR555 green 0x03E0, low byte
        0x8D, 0x22, 0x21,  # STA $2122
        0xA9, 0x03,        # LDA #$03     high byte
        0x8D, 0x22, 0x21,  # STA $2122
        0xA9, 0x0F,        # LDA #$0F
        0x8D, 0x00, 0x21,  # STA $2100    display on, full brightness
        0x80, 0xFE,        # BRA *
    ])
    rom[0:len(code)] = code
    rti = 0x0040
    rom[rti] = 0x40        # RTI

    header = 0x7FC0
    rom[header:header + 21] = b"MSU1 PROBE".ljust(21, b" ")
    rom[header + 0x15] = 0x20   # LoROM
    rom[header + 0x16] = 0x00   # ROM only
    rom[header + 0x17] = 0x05   # 32 KB
    rom[header + 0x18] = 0x00   # no SRAM
    rom[header + 0x19] = 0x01   # North America (NTSC)
    rom[header + 0x1A] = 0x00
    rom[header + 0x1B] = 0x00

    def vector(offset, target):
        struct.pack_into("<H", rom, offset, 0x8000 + target)

    for v in (0x7FE4, 0x7FE6, 0x7FE8, 0x7FEA, 0x7FEC, 0x7FEE,
              0x7FF4, 0x7FF8, 0x7FFA, 0x7FFE):
        vector(v, rti)
    vector(0x7FFC, 0x0000)  # reset

    struct.pack_into("<HH", rom, header + 0x1C, 0xFFFF, 0x0000)
    checksum = sum(rom) & 0xFFFF
    struct.pack_into("<HH", rom, header + 0x1C, checksum ^ 0xFFFF, checksum)
    return bytes(rom)


def cmd_files(args):
    out = args.outdir
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, ROM_NAME + ".sfc"), "wb") as f:
        f.write(make_rom())
    write_pattern_file(os.path.join(out, ROM_NAME + ".msu"), TAG_MSU, MSU_SIZE)
    write_pattern_file(os.path.join(out, ROM_NAME + "-1.pcm"), TAG_PCM, PCM_SIZE,
                       header=b"MSU1" + struct.pack("<I", 0))
    silence = b"MSU1" + struct.pack("<I", 0) + bytes(1024)
    for track in range(2, DIRECTORY_TRACKS + 1):
        with open(os.path.join(out, "%s-%d.pcm" % (ROM_NAME, track)), "wb") as f:
            f.write(silence)
    print("Wrote the probe test set to", out)


# ----------------------------------------------------------------------------
# Log decoding


def ms(cycles):
    return cycles * 1000.0 / CLOCK_HZ


def struct_string(words):
    """Path bytes are big-endian within each datatable word."""
    raw = b"".join(struct.pack(">I", w) for w in words)
    end = raw.find(b"\0")
    text = raw[: end if end >= 0 else len(raw)]
    return text.decode("utf-8", "replace"), raw


def decode_packed(v):
    return v >> 8, v & 7


def cmd_decode(args):
    data = open(args.log, "rb").read()
    if len(data) < 16:
        sys.exit("File too short")
    n = len(data) // 4
    w = list(struct.unpack("<%dI" % n, data[: n * 4]))
    w += [0] * (1024 - len(w))

    magic = struct.pack("<I", w[0])
    print("File: %s (%d bytes), magic %r, version %d" % (args.log, len(data), magic, w[1]))
    if magic != b"MSUP":
        print("WARNING: magic is not MSUP; is this the probe log?")

    r = w[L_RESULTS: L_RESULTS + 64]

    print("\n== Raw results")
    for idx, label, text in RESULTS:
        print("  R%02d %-3s %08X  %s" % (idx, label or "", r[idx], text))

    status = r[0]
    print("\n== Status")
    print("  done=%d aborted=%d last step=%d, run time %.1f s" % (
        status >> 31, (status >> 30) & 1, status & 0xFF, r[1] * 1024 / CLOCK_HZ))
    print("  APF reset exit %.1f ms after PLL lock; first command done %.1f ms later" % (
        ms(r[2]), ms(r[3])))
    print("  bridge_endian_little = %d" % r[55])

    def res(idx, table):
        return "%d (%s)" % (r[idx] & 7, table.get(r[idx] & 7, "?"))

    print("\n== P1: path of the ROM (0x0190 slot 0)")
    rom_path, rom_raw = struct_string(w[L_RESP_ROM: L_RESP_ROM + 64])
    print("  result %s in %.2f ms" % (res(4, GETFILE_RESULTS), ms(r[5])))
    print("  path   %r" % rom_path)
    print("  raw    %s" % rom_raw[:64].hex())

    print("\n== 0x0190 on an empty deferload slot (20)")
    empty_path, _ = struct_string(w[L_RESP_EMPTY: L_RESP_EMPTY + 64])
    print("  result %s in %.2f ms, response %r" % (res(6, GETFILE_RESULTS), ms(r[7]), empty_path))

    print("\n== P2: opening files (0x0192)")
    msu_param, _ = struct_string(w[L_PARAM_MSU: L_PARAM_MSU + 64])
    pcm_param, _ = struct_string(w[L_PARAM_PCM: L_PARAM_PCM + 64])
    print("  built .msu path %r (ok=%d len=%d)" % (msu_param, r[53] >> 16 & 1, r[53] & 0x1FF))
    print("  built .pcm path %r (ok=%d len=%d)" % (pcm_param, r[54] >> 16 & 1, r[54] & 0x1FF))
    print("  flags/size words sent: .msu %08X %08X, .pcm %08X %08X" % (
        w[L_PARAM_MSU + 64], w[L_PARAM_MSU + 65], w[L_PARAM_PCM + 64], w[L_PARAM_PCM + 65]))
    for label, e, t in ((".msu -> slot 21", 8, 9), ("-1.pcm -> slot 20 (read-only)", 12, 13),
                        ("-1.pcm -> slot 22 (reloadable)", 14, 15),
                        ("-65535.pcm (missing)", 16, 17), ("-100.pcm", 18, 19),
                        ("-1.pcm again", 20, 21)):
        if r[e] == 0x80:
            print("  %-32s not attempted: no path could be built" % label)
        else:
            print("  %-32s result %-22s %8.2f ms" % (label, res(e, OPEN_RESULTS), ms(r[t])))
    msu_resp, _ = struct_string(w[L_RESP_MSU: L_RESP_MSU + 64])
    print("  0x0190 slot 21 after open: result %s, path %r%s" % (
        res(10, GETFILE_RESULTS), msu_resp,
        "  (matches)" if msu_resp == msu_param else "  (DIFFERS from what was opened)"))
    print("  read slot: %d (%s)" % (r[22] & 0xFFFF, "usable" if r[22] >> 31 else "no slot opened"))

    print("\n== P3: APF's datatable, {slot id, size} per data.json entry")
    print("  (the core itself writes the sizes of the Save and Probe Log slots)")
    slot_names = ["0 Cartridge", "10 Save", "30 Probe Log", "20 MSU-1 Audio",
                  "21 MSU-1 Data", "22 Audio Test"]
    print("  %-20s %s" % ("", " ".join("%-19s" % n for n in slot_names)))
    for name, base in L_SNAP.items():
        cells = []
        for i in range(len(slot_names)):
            sid, size = w[base + 2 * i], w[base + 2 * i + 1]
            cells.append("%-19s" % ("id %d, %d" % (sid, size)))
        print("  %-20s %s" % (name, " ".join(cells)))
        extra = [(i, w[base + i]) for i in range(2 * len(slot_names), 64) if w[base + i]]
        if extra:
            print("  %-20s other nonzero words: %s" % ("", extra))
    print("  size of slot 20 / 21 / 22 at boot: %d / %d / %d" % (r[56], r[57], r[58]))
    print("  size of slot 20 / 21 / 22 at end:  %d / %d / %d" % (r[47], r[48], r[49]))

    print("\n== P5: sequential throughput (512 KB per read size)")
    for k, size in enumerate((4, 8, 16, 32, 64)):
        total, worst = r[24 + 2 * k], r[25 + 2 * k]
        if total:
            print("  %2d KB reads: %7.0f KB/s, slowest read %6.2f ms" % (
                size, 512 / (total / CLOCK_HZ), ms(worst)))
        else:
            print("  %2d KB reads: no data" % size)
        times = ["%.1f" % ms(t) for t in w[L_TP_READS + 16 * k: L_TP_READS + 16 * k + 16] if t]
        print("      first reads (ms): %s" % " ".join(times))
    print("  reads with errors: %d, pattern mismatches: %d" % (r[34], r[23]))
    if r[23]:
        print("  first mismatch at file offset %08X: got %08X" % (r[51], r[52]))
    print("  first raw bridge word: %08X" % r[50])

    print("\n== P5: scattered 4 KB reads")
    offsets = [0xF00000, 0x100000, 0x800000, 0xC00000, 0x400000, 0, 0xE00000, 0x600000]
    for i, off in enumerate(offsets):
        words, err = decode_packed(w[L_RND + 8 + i])
        print("  offset %5d KB: %6.2f ms  result %d, %d words" % (
            off // 1024, ms(w[L_RND + i]), err, words))
    print("  total %.1f ms, slowest %.2f ms, bad reads %d" % (ms(r[35]), ms(r[36]), r[60]))

    print("\n== P6: alternating reads between slot 20/22 (.pcm) and slot 21 (.msu)")
    if r[37]:
        pcm = [ms(w[L_ALT + i]) for i in range(0, 32, 2)]
        msu = [ms(w[L_ALT + i]) for i in range(1, 32, 2)]
        print("  .pcm reads (ms): %s" % " ".join("%.1f" % t for t in pcm))
        print("  .msu reads (ms): %s" % " ".join("%.1f" % t for t in msu))
        print("  total %.1f ms, slowest %.2f ms, bad reads %d" % (ms(r[37]), ms(r[38]), r[59]))
    else:
        print("  not run (.msu did not open)")

    print("\n== P4: end of file")
    print("  size search: %d reads, %.1f ms, last good 4 KB offset %d" % (
        r[40], ms(r[41]), r[39]))
    for i in range(min(r[40], 40)):
        words, err = decode_packed(w[L_SIZE + 2 * i + 1])
        print("    read @%10d -> result %d, %d words" % (w[L_SIZE + 2 * i], err, words))
    for label, idx in (("4 KB read crossing EOF", 42), ("len FFFFFFFF from SZO+4K", 43),
                       ("len FFFFFFFF from estimated size", 44), ("len FFFFFFFF from SZO", 45),
                       ("4 bytes at 0x7FFF0000", 46)):
        words, err = decode_packed(r[idx])
        print("  %-34s result %d (%s), %d words (%d bytes)" % (
            label, err, READ_RESULTS.get(err, "?"), words, words * 4))
    print("  estimated file size: %d" % r[61])
    if rom_path.endswith(ROM_NAME + ".sfc"):
        print("  generated test file size:  %d  -> %s" % (
            PCM_SIZE, "MATCH" if r[61] == PCM_SIZE else "mismatch"))


# ----------------------------------------------------------------------------
# RTL generation (font and screen template ROMs)

FONT = {
    " ": ["00000"] * 7,
    "!": ["00100", "00100", "00100", "00100", "00100", "00000", "00100"],
    '"': ["01010", "01010", "01010", "00000", "00000", "00000", "00000"],
    "#": ["01010", "01010", "11111", "01010", "11111", "01010", "01010"],
    "$": ["00100", "01111", "10100", "01110", "00101", "11110", "00100"],
    "%": ["11000", "11001", "00010", "00100", "01000", "10011", "00011"],
    "&": ["01100", "10010", "10100", "01000", "10101", "10010", "01101"],
    "'": ["01100", "00100", "01000", "00000", "00000", "00000", "00000"],
    "(": ["00010", "00100", "01000", "01000", "01000", "00100", "00010"],
    ")": ["01000", "00100", "00010", "00010", "00010", "00100", "01000"],
    "*": ["00000", "00100", "10101", "01110", "10101", "00100", "00000"],
    "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
    ",": ["00000", "00000", "00000", "00000", "01100", "00100", "01000"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    "/": ["00000", "00001", "00010", "00100", "01000", "10000", "00000"],
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
    ";": ["00000", "01100", "01100", "00000", "01100", "00100", "01000"],
    "<": ["00010", "00100", "01000", "10000", "01000", "00100", "00010"],
    "=": ["00000", "00000", "11111", "00000", "11111", "00000", "00000"],
    ">": ["01000", "00100", "00010", "00001", "00010", "00100", "01000"],
    "?": ["01110", "10001", "00001", "00010", "00100", "00000", "00100"],
    "@": ["01110", "10001", "00001", "01101", "10101", "10101", "01110"],
    "A": ["01110", "10001", "10001", "10001", "11111", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11100", "10010", "10001", "10001", "10001", "10010", "11100"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "10001", "11001", "10101", "10011", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "10001", "01010", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "[": ["01110", "01000", "01000", "01000", "01000", "01000", "01110"],
    "\\": ["00000", "10000", "01000", "00100", "00010", "00001", "00000"],
    "]": ["01110", "00010", "00010", "00010", "00010", "00010", "01110"],
    "^": ["00100", "01010", "10001", "00000", "00000", "00000", "00000"],
    "_": ["00000", "00000", "00000", "00000", "00000", "00000", "11111"],
    "`": ["01000", "00100", "00010", "00000", "00000", "00000", "00000"],
    "a": ["00000", "00000", "01110", "00001", "01111", "10001", "01111"],
    "b": ["10000", "10000", "10110", "11001", "10001", "10001", "11110"],
    "c": ["00000", "00000", "01110", "10000", "10000", "10001", "01110"],
    "d": ["00001", "00001", "01101", "10011", "10001", "10001", "01111"],
    "e": ["00000", "00000", "01110", "10001", "11111", "10000", "01110"],
    "f": ["00110", "01001", "01000", "11100", "01000", "01000", "01000"],
    "g": ["00000", "01111", "10001", "10001", "01111", "00001", "01110"],
    "h": ["10000", "10000", "10110", "11001", "10001", "10001", "10001"],
    "i": ["00100", "00000", "01100", "00100", "00100", "00100", "01110"],
    "j": ["00010", "00000", "00110", "00010", "00010", "10010", "01100"],
    "k": ["10000", "10000", "10010", "10100", "11000", "10100", "10010"],
    "l": ["01100", "00100", "00100", "00100", "00100", "00100", "01110"],
    "m": ["00000", "00000", "11010", "10101", "10101", "10001", "10001"],
    "n": ["00000", "00000", "10110", "11001", "10001", "10001", "10001"],
    "o": ["00000", "00000", "01110", "10001", "10001", "10001", "01110"],
    "p": ["00000", "00000", "11110", "10001", "11110", "10000", "10000"],
    "q": ["00000", "00000", "01101", "10011", "01111", "00001", "00001"],
    "r": ["00000", "00000", "10110", "11001", "10000", "10000", "10000"],
    "s": ["00000", "00000", "01110", "10000", "01110", "00001", "11110"],
    "t": ["01000", "01000", "11100", "01000", "01000", "01001", "00110"],
    "u": ["00000", "00000", "10001", "10001", "10001", "10011", "01101"],
    "v": ["00000", "00000", "10001", "10001", "10001", "01010", "00100"],
    "w": ["00000", "00000", "10001", "10001", "10101", "10101", "01010"],
    "x": ["00000", "00000", "10001", "01010", "00100", "01010", "10001"],
    "y": ["00000", "00000", "10001", "10001", "01111", "00001", "01110"],
    "z": ["00000", "00000", "11111", "00010", "00100", "01000", "11111"],
    "{": ["00010", "00100", "00100", "01000", "00100", "00100", "00010"],
    "|": ["00100", "00100", "00100", "00100", "00100", "00100", "00100"],
    "}": ["01000", "00100", "00100", "00010", "00100", "00100", "01000"],
    "~": ["00000", "00000", "01000", "10101", "00010", "00000", "00000"],
}


def font_bytes():
    out = []
    for code in range(0x20, 0x80):
        rows = FONT.get(chr(code), ["00000"] * 7) + ["00000"]
        for row in rows:
            out.append(int(row, 2) << 2)  # 5 pixels wide, starting at column 1
    return out


def screen_template():
    rows = []
    rows.append("MSU-1 PROBE 1  START=GAME   S:--")
    rows += [" " * 32] * 3
    labels = {idx: label for idx, label, _ in RESULTS if label}
    for row in range(24):
        a, b = 2 * row, 2 * row + 1
        rows.append("%-3s %s  %-3s %s      " % (labels[a], "-" * 8, labels[b], "-" * 8))
    text = "".join(r[:32].ljust(32) for r in rows)
    assert len(text) == 32 * 28
    return text.ljust(1024)


def rom_module(name, values, comment):
    lines = ["module %s (" % name,
             "    input wire clk,",
             "    input wire [9:0] addr,",
             "    output reg [7:0] q = 0",
             ");",
             "  // %s" % comment,
             "  always @(posedge clk) begin",
             "    case (addr)"]
    for i, v in enumerate(values):
        if v:
            lines.append("      10'd%d: q <= 8'h%02X;" % (i, v))
    lines += ["      default: q <= 8'h%02X;" % (0x20 if name.endswith("template") else 0),
              "    endcase", "  end", "endmodule", ""]
    return "\n".join(lines)


def cmd_rtl(args):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, "target", "pocket", "msu", "msu_probe_rom.sv")
    template = [ord(c) for c in screen_template()]
    font = font_bytes()
    with open(path, "w") as f:
        f.write("// Generated by tools/msu_probe.py rtl. Do not edit.\n\n")
        f.write(rom_module("msu_probe_template",
                           [c if c != 0x20 else 0 for c in template],
                           "32x28 screen of labels; unlisted addresses are spaces"))
        f.write("\n")
        f.write(rom_module("msu_probe_font", font,
                           "8x8 glyphs for ASCII 0x20-0x7F, address = (char - 0x20) * 8 + row"))
    print("Wrote", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("files", help="write the test file set")
    p.add_argument("outdir")
    p.set_defaults(func=cmd_files)
    p = sub.add_parser("decode", help="decode a probe log")
    p.add_argument("log")
    p.set_defaults(func=cmd_decode)
    p = sub.add_parser("rtl", help="regenerate msu_probe_rom.sv")
    p.set_defaults(func=cmd_rtl)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
