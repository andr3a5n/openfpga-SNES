#!/usr/bin/env python3
"""Decode the MSU-1 event log of the SNESMSU core.

  msu_log.py FILE.msulog [--all]

The core keeps the last 2048 MSU-1 events and the Pocket saves them when the
core is quit, next to the save files (Saves/snes/.../<rom>.msulog). The format
is in target/pocket/msu/msu_log.sv, the event codes in msu_ev.sv.

Prints a timeline and a summary: how long the game waited on the audio-busy
bit for each track change, how long tracks took to open and start, sector
requests that had to wait, slow reads and flushes. --all also lists the ROM
address samples (every 8 frames), which are otherwise folded into runs.
"""

import argparse
import struct
import sys

DEPTH = 2048
US_PER_CYCLE = 1 / 74.25

KIND = {0: "read", 1: "getfile", 2: "open", 3: "?"}
RESULT = {0: "ok", 1: "slot not defined", 2: "error/out of range", 3: "not found",
          4: "malformed", 5: "?", 6: "?", 7: "no answer"}


def describe(t, d):
    if t == 0x10:
        return "boot"
    if t == 0x11:
        return {0: "boot: no MSU-1 files, MSU-1 off", 1: "boot: .msu found, MSU-1 on",
                2: "boot: no .msu but track 1 found, MSU-1 on"}.get(d, "boot: %d" % d)
    if t == 0x12:
        return "boot: %d bytes of the data file preloaded" % d
    if t == 0x13:
        track, kb = d >> 16, d & 0xFFFF
        return "scan: track %d %s" % (track, "missing" if kb == 0 else "%d KB" % kb)
    if t == 0x14:
        return "boot done: tracks 0-%d in the table" % (d & 0xFF)
    if t == 0x20:
        return "host: track %d requested" % (d & 0xFFFF)
    if t == 0x21:
        fast, missing, track = (d >> 23) & 1, (d >> 22) & 1, d & 0xFFFF
        return "host: track %d answered %s (%s)" % (track, "MISSING" if missing else "present",
                                                    "from the table" if fast else "after opening")
    if t == 0x22:
        return "host: track ready, loop sector %s" % (d & 0x3FFFFF if d >> 23 else "none")
    if t == 0x23:
        return "host: TRACK FAILED after answering, result %s" % RESULT.get(d & 7, d)
    if t == 0x24:
        return "host: track %d abandoned for a newer request" % (d & 0xFFFF)
    if t == 0x30:
        kind = d >> 22
        if kind == 0:
            return "cmd: read at %d KB" % (d & 0x3FFFFF)
        return "cmd: %s slot %d" % (KIND[kind], d & 0xFFFF)
    if t == 0x31:
        timeout, res = d >> 23, (d >> 20) & 7
        return "cmd done: %s%s" % (RESULT.get(res, res), " (TIMEOUT)" if timeout else "")
    if t == 0x32:
        return "host: queue flushed, refill from sector %d" % d
    if t == 0x33:
        return "host: SLOW READ, %.1f ms" % (d * 64 * US_PER_CYCLE / 1000)
    if t == 0x40:
        return "host: sector %d requested, not queued yet" % d
    if t == 0x41:
        return "host: sector %d delivered" % d
    if t == 0x42:
        return "host: sector %d served as silence" % d
    if t == 0x80:
        return "SNES: track %d selected ($2004/5)" % (d & 0xFFFF)
    if t == 0x81:
        return "SNES: audio busy cleared"
    if t == 0x82:
        flags = [n for b, n in ((0, "play"), (1, "repeat"), (2, "resume")) if d >> b & 1]
        return "SNES: control %s" % ("+".join(flags) if flags else "stop")
    if t == 0x83:
        return "SNES: volume %d" % d
    if t == 0x84:
        return "SNES: track ended (no repeat)"
    if t == 0x85:
        return "SNES: data port seek to %06X" % d
    if t == 0x86:
        return "SNES: data port seek done"
    if t == 0x87:
        return "SNES: CPU/ROM at %06X" % d
    if t == 0x88:
        return "SNES: reset %s" % ("asserted" if d else "released")
    if t == 0xF0:
        return "LOG: %d events lost so far" % d
    return "event %02X data %06X" % (t, d)


def load(path):
    raw = open(path, "rb").read()
    if len(raw) < 16 or raw[:4] != b"MSUL":
        sys.exit("%s is not an MSU-1 event log" % path)
    version, written, lost = struct.unpack("<III", raw[4:16])
    entries = []
    for i in range(min(written, DEPTH)):
        n = written - min(written, DEPTH) + i
        off = 16 + 8 * (n % DEPTH)
        us, ev = struct.unpack("<II", raw[off:off + 8])
        entries.append((n, us, ev >> 24, ev & 0xFFFFFF))
    return version, written, lost, entries


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--all", action="store_true", help="list every ROM address sample")
    args = ap.parse_args()

    version, written, lost, entries = load(args.log)
    print("MSU-1 event log, format %d: %d events since power-on, last %d kept, %d lost"
          % (version, written, len(entries), lost))
    if not entries:
        return

    # Timeline. Times wrap after 71 minutes; unwrap them.
    t_prev, wraps = None, 0
    timeline = []
    for n, us, t, d in entries:
        if t_prev is not None and us < t_prev:
            wraps += 1
        t_prev = us
        timeline.append((us + wraps * (1 << 32), t, d))

    print()
    print("     time (ms)  event")
    rom_run = []

    def flush_rom():
        if rom_run:
            if len(rom_run) == 1:
                print("%14.3f  %s" % (rom_run[0][0] / 1000, describe(0x87, rom_run[0][1])))
            else:
                addrs = sorted(set(a for _, a in rom_run))
                print("%14.3f  SNES: CPU/ROM samples x%d until %.3f ms: %s%s" % (
                    rom_run[0][0] / 1000, len(rom_run), rom_run[-1][0] / 1000,
                    " ".join("%06X" % a for a in addrs[:6]), " ..." if len(addrs) > 6 else ""))
            rom_run.clear()

    for us, t, d in timeline:
        if t == 0x87 and not args.all:
            rom_run.append((us, d))
            continue
        flush_rom()
        print("%14.3f  %s" % (us / 1000, describe(t, d)))
    flush_rom()

    # Summary
    print()
    print("Summary")
    busy, opens, starts, waits = [], [], [], []
    sel = None
    req = None
    wait_start = {}
    cmd = None
    for us, t, d in timeline:
        if t == 0x80:
            sel = (us, d & 0xFFFF)
        elif t == 0x81 and sel:
            busy.append((sel[1], us - sel[0]))
            sel = None
        elif t == 0x20:
            req = (us, d & 0xFFFF)
        elif t == 0x22 and req:
            starts.append((req[1], us - req[0]))
            req = None
        elif t == 0x30 and (d >> 22) == 2:
            cmd = us
        elif t == 0x31 and cmd is not None:
            opens.append(us - cmd)
            cmd = None
        elif t == 0x40:
            wait_start[d] = us
        elif t == 0x41 and d in wait_start:
            waits.append((d, us - wait_start.pop(d)))

    def stats(values):
        return "min %.1f ms, max %.1f ms, mean %.1f ms" % (
            min(values) / 1000, max(values) / 1000, sum(values) / len(values) / 1000)

    if busy:
        print("  audio busy per track selection (%d): %s" % (len(busy), stats([b for _, b in busy])))
        worst = sorted(busy, key=lambda x: -x[1])[:5]
        print("    longest: " + ", ".join("track %d %.1f ms" % (t, b / 1000) for t, b in worst))
    if opens:
        print("  file opens (%d): %s" % (len(opens), stats(opens)))
    if starts:
        print("  track request to first data (%d): %s" % (len(starts), stats([s for _, s in starts])))
    if waits:
        print("  sector requests that waited (%d): %s" % (len(waits), stats([w for _, w in waits])))
        slow = [w for w in waits if w[1] > 17000]
        if slow:
            print("    %d waited longer than msu_audio's 17 ms buffer: audible gaps likely" % len(slow))
    counts = {}
    for _, t, _ in timeline:
        counts[t] = counts.get(t, 0) + 1
    for t, name in ((0x32, "queue flushes"), (0x33, "slow reads (>30 ms)"),
                    (0x42, "sectors served as silence"), (0x23, "tracks failed after answering"),
                    (0x24, "mounts abandoned")):
        if counts.get(t):
            print("  %s: %d" % (name, counts[t]))


if __name__ == "__main__":
    main()
