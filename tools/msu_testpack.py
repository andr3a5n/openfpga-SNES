#!/usr/bin/env python3
"""MSU-1 test files.

  msu_testpack.py sim OUTDIR    Pattern files for sim/msu/tb_msu_play.sv
  msu_testpack.py hw OUTDIR     Test ROM and tracks for the Pocket

sim: every sample of a pattern track is predictable, so the testbench can
check the audio bit-exact. The generator and the testbench must agree on the
formulas below.

hw: msu1test.sfc, a 32 KB LoROM that checks the MSU-1 registers and the data
port, then plays msu1test-1.pcm. The backdrop colour shows the state:

  grey     starting, or stopped
  red      no MSU-1 (msu1test.msu missing, or not the MSU-1 core)
  magenta  the data port returned wrong bytes
  yellow   the selected track is missing
  green    track 1 playing: a tone on the left, the same on the right, then
           an arpeggio that loops
  blue     track 2 playing: three falling notes, once; grey when it ends
  white    track 1 paused with resume

  A: track 1   B: track 2   X: pause track 1 / resume it   Y: stop
  Up/Down: MSU-1 volume
"""

import argparse
import math
import os
import struct
import sys

SIM_NAME = "msutest"

# track: (samples, loop point in samples)
SIM_TRACKS = {
    1: (12000, 5000),  # longer than the queue in simulation (32 KB)
    2: (3000, 0),      # shorter than one 16 KB read
}
SIM_DATA_SIZE = 100 * 1024 + 3


def pattern_sample(track, k):
    left = (2 * k + track) & 0xFFFF
    right = (3 * k + 0x100 * track) & 0xFFFF
    return left, right


def pattern_data_byte(i):
    return (i * 7 + (i >> 8)) & 0xFF


def write_pcm(path, samples, loop, sample_fn):
    with open(path, "wb") as f:
        f.write(b"MSU1" + struct.pack("<I", loop))
        f.write(b"".join(struct.pack("<HH", *sample_fn(k)) for k in range(samples)))


# ---------------------------------------------------------------------------
# Hardware test pack

HW_NAME = "msu1test"
RATE = 44100


class Asm65816:
    """Just enough of a two-pass 65816 assembler for the test ROM. Operand
    sizes are explicit: the mnemonic suffix says the addressing mode."""

    # mnemonic -> (opcode, operand bytes, kind)
    OPS = {
        "sei": (0x78, 0, None), "clc": (0x18, 0, None), "xce": (0xFB, 0, None),
        "rep": (0xC2, 1, "imm"), "sep": (0xE2, 1, "imm"),
        "txs": (0x9A, 0, None), "tcd": (0x5B, 0, None), "txa": (0x8A, 0, None),
        "xba": (0xEB, 0, None), "inx": (0xE8, 0, None), "iny": (0xC8, 0, None),
        "rts": (0x60, 0, None), "rti": (0x40, 0, None), "sec": (0x38, 0, None),
        "lda#8": (0xA9, 1, "imm"), "lda#16": (0xA9, 2, "imm"),
        "ldx#16": (0xA2, 2, "imm"), "ldy#16": (0xA0, 2, "imm"),
        "cmp#8": (0xC9, 1, "imm"), "cmp#16": (0xC9, 2, "imm"),
        "cpx#16": (0xE0, 2, "imm"), "cpy#16": (0xC0, 2, "imm"),
        "and#8": (0x29, 1, "imm"), "and#16": (0x29, 2, "imm"),
        "eor#16": (0x49, 2, "imm"), "adc#8": (0x69, 1, "imm"), "sbc#8": (0xE9, 1, "imm"),
        "lda": (0xAD, 2, "abs"), "sta": (0x8D, 2, "abs"), "stz": (0x9C, 2, "abs"),
        "bit": (0x2C, 2, "abs"), "and": (0x2D, 2, "abs"),
        "lda,x": (0xBD, 2, "abs"), "cmp,x": (0xDD, 2, "abs"),
        "lda.d": (0xA5, 1, "abs"), "sta.d": (0x85, 1, "abs"), "stz.d": (0x64, 1, "abs"),
        "cmp.d": (0xC5, 1, "abs"), "and.d": (0x25, 1, "abs"),
        "jsr": (0x20, 2, "abs"), "jmp": (0x4C, 2, "abs"),
        "bne": (0xD0, 1, "rel"), "beq": (0xF0, 1, "rel"), "bra": (0x80, 1, "rel"),
        "bpl": (0x10, 1, "rel"), "bmi": (0x30, 1, "rel"), "bvs": (0x70, 1, "rel"),
        "bcc": (0x90, 1, "rel"), "bcs": (0xB0, 1, "rel"),
    }

    def __init__(self, org):
        self.org = org
        self.items = []

    def label(self, name):
        self.items.append(("label", name))

    def data(self, raw):
        self.items.append(("data", bytes(raw)))

    def __getattr__(self, name):
        mnemonic = name.rstrip("_").replace("_imm8", "#8").replace("_imm16", "#16") \
            .replace("_x", ",x").replace("_dp", ".d")
        if mnemonic not in self.OPS:
            raise AttributeError(name)
        return lambda operand=None: self.items.append(("op", mnemonic, operand))

    def assemble(self):
        labels = {}
        for final in (False, True):
            pc = self.org
            out = bytearray()
            for item in self.items:
                if item[0] == "label":
                    labels[item[1]] = pc
                    continue
                if item[0] == "data":
                    out += item[1]
                    pc += len(item[1])
                    continue
                opcode, size, kind = self.OPS[item[1]]
                value = item[2]
                if isinstance(value, str):
                    value = labels.get(value, 0) if not final else labels[value]
                out.append(opcode)
                if kind == "rel":
                    offset = value - (pc + 2)
                    if final and not -128 <= offset <= 127:
                        raise ValueError("branch out of range: %s" % item[2])
                    out.append(offset & 0xFF)
                elif size:
                    out += (value & ((1 << (8 * size)) - 1)).to_bytes(size, "little")
                pc += 1 + size
        return bytes(out), labels


# Backdrop colours, BGR555
GREY, RED, MAGENTA, YELLOW, GREEN, BLUE, WHITE = (
    0x4210, 0x001F, 0x7C1F, 0x03FF, 0x03E0, 0x7C00, 0x7FFF)

# Direct page
DP_EXPECT, DP_VOLUME, DP_STATE, DP_PREV, DP_PRESSED = 0x00, 0x02, 0x04, 0x06, 0x08

# Joypad 1 bits as read from $4218 (16-bit)
PAD_A, PAD_X, PAD_B, PAD_Y, PAD_UP, PAD_DOWN = 0x0080, 0x0040, 0x8000, 0x4000, 0x0800, 0x0400


def test_rom():
    a = Asm65816(0x8000)

    a.label("reset")
    a.sei(); a.clc(); a.xce()           # native mode
    a.rep(0x38)                          # 16-bit A, X, Y; binary mode
    a.ldx_imm16(0x1FFF); a.txs()
    a.lda_imm16(0x0000); a.tcd()
    a.sep(0x20)                          # 8-bit A from here on
    a.lda_imm8(0x8F); a.sta(0x2100)      # forced blank
    a.stz(0x4200)
    for reg in (0x212C, 0x212D, 0x2130, 0x2131, 0x2133):
        a.stz(reg)
    a.stz_dp(DP_STATE)
    a.ldx_imm16(GREY); a.jsr("set_color")

    # "S-MSU1" at $2002-$2007
    a.ldx_imm16(0)
    a.label("id_loop")
    a.lda_x(0x2002); a.cmp_x("id_string"); a.bne("no_msu")
    a.inx(); a.cpx_imm16(6); a.bne("id_loop")

    # Data port: seek to 0, read 1024 bytes of the pattern
    for reg in (0x2000, 0x2001, 0x2002, 0x2003):
        a.stz(reg)
    a.label("data_wait")
    a.bit(0x2000); a.bmi("data_wait")     # bit 7: data busy
    a.stz_dp(DP_EXPECT)
    a.ldy_imm16(0)
    a.label("data_loop")
    a.lda(0x2001); a.cmp_dp(DP_EXPECT); a.bne("data_bad")
    a.iny()
    # expected = (i * 7 + (i >> 8)) & 0xFF: add 7, plus 1 more every 256 bytes
    a.lda_dp(DP_EXPECT); a.clc(); a.adc_imm8(7); a.sta_dp(DP_EXPECT)
    a.cpy_imm16(0x100); a.beq("data_carry")
    a.cpy_imm16(0x200); a.beq("data_carry")
    a.cpy_imm16(0x300); a.beq("data_carry")
    a.bra("data_next")
    a.label("data_carry")
    a.lda_dp(DP_EXPECT); a.clc(); a.adc_imm8(1); a.sta_dp(DP_EXPECT)
    a.label("data_next")
    a.cpy_imm16(0x400); a.bne("data_loop")
    a.bra("checks_ok")

    a.label("no_msu")
    a.ldx_imm16(RED); a.jsr("set_color")
    a.label("halt")
    a.bra("halt")

    a.label("data_bad")
    a.ldx_imm16(MAGENTA); a.jsr("set_color")
    a.bra("halt")

    a.label("checks_ok")

    a.lda_imm8(0xFF); a.sta_dp(DP_VOLUME)
    a.lda_imm8(0x01); a.sta(0x4200)      # joypad auto-read, no NMI
    a.jsr("play_track1")

    a.label("main_loop")
    a.label("wait_vblank")
    a.lda(0x4212); a.bpl("wait_vblank")
    a.label("wait_autoread")
    a.lda(0x4212); a.and_imm8(0x01); a.bne("wait_autoread")
    a.rep(0x20)
    a.lda_dp(DP_PREV); a.eor_imm16(0xFFFF); a.and_(0x4218); a.sta_dp(DP_PRESSED)
    a.lda(0x4218); a.sta_dp(DP_PREV)

    for mask, target in ((PAD_A, "on_a"), (PAD_B, "on_b"), (PAD_X, "on_x"),
                         (PAD_Y, "on_y"), (PAD_UP, "on_up"), (PAD_DOWN, "on_down")):
        a.lda_dp(DP_PRESSED); a.and_imm16(mask); a.beq("skip_" + target)
        a.sep(0x20); a.jsr(target); a.rep(0x20)
        a.label("skip_" + target)
    a.sep(0x20)

    # Track 2 plays once: grey when it has stopped
    a.lda_dp(DP_STATE); a.cmp_imm8(2); a.bne("wait_active")
    a.lda(0x2000); a.and_imm8(0x10); a.bne("wait_active")
    a.stz_dp(DP_STATE)
    a.ldx_imm16(GREY); a.jsr("set_color")

    a.label("wait_active")
    a.lda(0x4212); a.bmi("wait_active")
    a.jmp("main_loop")

    a.label("on_a")
    a.jmp("play_track1")

    a.label("on_b")
    a.lda_imm8(2); a.jsr("select_track"); a.bcs("on_b_done")
    a.lda_imm8(0x01); a.sta(0x2007)
    a.lda_imm8(2); a.sta_dp(DP_STATE)
    a.ldx_imm16(BLUE); a.jsr("set_color")
    a.label("on_b_done")
    a.rts()

    a.label("on_x")
    a.lda_dp(DP_STATE); a.cmp_imm8(1); a.bne("on_x_resume")
    a.lda_imm8(0x04); a.sta(0x2007)       # stop, keep the position
    a.lda_imm8(3); a.sta_dp(DP_STATE)
    a.ldx_imm16(WHITE); a.jmp("set_color")
    a.label("on_x_resume")
    a.cmp_imm8(3); a.bne("on_x_done")
    a.jmp("play_track1")                  # selecting it again resumes
    a.label("on_x_done")
    a.rts()

    a.label("on_y")
    a.stz(0x2007)
    a.stz_dp(DP_STATE)
    a.ldx_imm16(GREY); a.jmp("set_color")

    a.label("on_up")
    a.lda_dp(DP_VOLUME); a.clc(); a.adc_imm8(0x20); a.bcc("vol_set")
    a.lda_imm8(0xFF); a.bra("vol_set")
    a.label("on_down")
    a.lda_dp(DP_VOLUME); a.cmp_imm8(0x20); a.bcs("vol_sub")
    a.lda_imm8(0); a.bra("vol_set")
    a.label("vol_sub")
    a.sec(); a.sbc_imm8(0x20)
    a.label("vol_set")
    a.sta_dp(DP_VOLUME); a.sta(0x2006)
    a.rts()

    a.label("play_track1")
    a.lda_imm8(1); a.jsr("select_track"); a.bcs("play_track1_done")
    a.lda_imm8(0x03); a.sta(0x2007)       # play, repeat
    a.lda_imm8(1); a.sta_dp(DP_STATE)
    a.ldx_imm16(GREEN); a.jsr("set_color")
    a.label("play_track1_done")
    a.rts()

    # A = track. Carry set if the track is missing.
    a.label("select_track")
    a.sta(0x2004); a.stz(0x2005)
    a.label("select_wait")
    a.bit(0x2000); a.bvs("select_wait")   # bit 6: audio busy
    a.lda(0x2000); a.and_imm8(0x08); a.bne("select_missing")
    a.lda_dp(DP_VOLUME); a.sta(0x2006)
    a.clc(); a.rts()
    a.label("select_missing")
    a.stz_dp(DP_STATE)
    a.ldx_imm16(YELLOW); a.jsr("set_color")
    a.sec(); a.rts()

    # X = colour. Written in forced blank, so it works at any time.
    a.label("set_color")
    a.lda_imm8(0x8F); a.sta(0x2100)
    a.stz(0x2121)
    a.rep(0x20); a.txa(); a.sep(0x20)
    a.sta(0x2122); a.xba(); a.sta(0x2122)
    a.lda_imm8(0x0F); a.sta(0x2100)
    a.rts()

    a.label("nmi")
    a.rti()

    a.label("id_string")
    a.data(b"S-MSU1")

    code, labels = a.assemble()
    rom = bytearray(b"\xFF" * 0x8000)
    rom[0:len(code)] = code

    header = b"MSU-1 POCKET TEST".ljust(21, b" ")
    rom[0x7FC0:0x7FD5] = header
    rom[0x7FD5] = 0x20  # LoROM
    rom[0x7FD6] = 0x00  # ROM only
    rom[0x7FD7] = 0x05  # 32 KB
    rom[0x7FD8] = 0x00  # no SRAM
    rom[0x7FD9] = 0x01  # North America: NTSC
    rom[0x7FDA] = 0x00
    rom[0x7FDB] = 0x00
    rom[0x7FDC:0x7FE0] = b"\xFF\xFF\x00\x00"
    nmi = labels["nmi"]
    for vec in range(0x7FE4, 0x8000, 2):
        rom[vec:vec + 2] = struct.pack("<H", nmi)
    rom[0x7FFC:0x7FFE] = struct.pack("<H", labels["reset"])
    checksum = sum(rom) & 0xFFFF
    rom[0x7FDC:0x7FE0] = struct.pack("<HH", checksum ^ 0xFFFF, checksum)
    return bytes(rom)


def tone(freq, seconds, amp=0.3, attack=0.01, release=0.05):
    n = int(seconds * RATE)
    out = []
    for i in range(n):
        env = min(1.0, i / (attack * RATE), (n - i) / (release * RATE))
        out.append(amp * env * math.sin(2 * math.pi * freq * i / RATE))
    return out


def write_tone_pcm(path, parts, loop):
    """parts: [(left samples, right samples)], floats in -1..1"""
    with open(path, "wb") as f:
        f.write(b"MSU1" + struct.pack("<I", loop))
        for left, right in parts:
            f.write(b"".join(struct.pack("<hh", int(l * 32767), int(r * 32767))
                             for l, r in zip(left, right)))


def cmd_hw(args):
    out = args.outdir
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, HW_NAME + ".sfc"), "wb") as f:
        f.write(test_rom())
    with open(os.path.join(out, HW_NAME + ".msu"), "wb") as f:
        f.write(bytes(pattern_data_byte(i) for i in range(64 * 1024)))

    # Track 1: left, right, then a looping arpeggio. The loop point is the
    # start of the arpeggio.
    a4 = tone(440.0, 0.6)
    silent = [0.0] * len(a4)
    intro = [(a4, silent), (silent, a4)]
    arpeggio = []
    for freq in (523.25, 659.25, 783.99, 1046.50):
        t = tone(freq, 0.4, amp=0.25)
        arpeggio.append((t, t))
    write_tone_pcm(os.path.join(out, "%s-1.pcm" % HW_NAME), intro + arpeggio,
                   loop=2 * len(a4))

    # Track 2: three falling notes, played once
    chime = []
    for freq in (783.99, 659.25, 523.25):
        t = tone(freq, 0.5, amp=0.25, release=0.3)
        chime.append((t, t))
    write_tone_pcm(os.path.join(out, "%s-2.pcm" % HW_NAME), chime, loop=0)
    print("Wrote the hardware test pack to", out)


def cmd_sim(args):
    out = args.outdir
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, SIM_NAME + ".sfc"), "wb") as f:
        f.write(bytes(32768))
    with open(os.path.join(out, SIM_NAME + ".msu"), "wb") as f:
        f.write(bytes(pattern_data_byte(i) for i in range(SIM_DATA_SIZE)))
    for track, (samples, loop) in SIM_TRACKS.items():
        write_pcm(os.path.join(out, "%s-%d.pcm" % (SIM_NAME, track)), samples, loop,
                  lambda k, t=track: pattern_sample(t, k))
    print("Wrote the simulation test pack to", out)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("sim", help="pattern files for the testbench")
    p.add_argument("outdir")
    p.set_defaults(func=cmd_sim)
    p = sub.add_parser("hw", help="test ROM and tracks for the Pocket")
    p.add_argument("outdir")
    p.set_defaults(func=cmd_hw)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
