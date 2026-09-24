#!/usr/bin/env python3
"""Run the MSU-1 hardware test ROM (tools/msu_testpack.py hw) on a model.

A 65816 interpreter for the instructions the ROM uses, with models of the
MSU-1 registers, $4212 and joypad 1. Each scenario scripts the MSU-1 side and
the buttons, and checks the backdrop colours and the register writes.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import msu_testpack as tp  # noqa: E402


class MSU:
    def __init__(self, present=True, data_ok=True, tracks=(1, 2, 3), once_frames=30):
        self.present = present
        self.data_ok = data_ok
        self.tracks = tracks
        self.once_frames = once_frames
        self.addr = 0
        self.data_busy = 0
        self.audio_busy = 0
        self.track = 0
        self.seek = [0, 0, 0]
        self.track_lo = 0
        self.missing = False
        self.playing = False
        self.repeat = False
        self.play_frames = 0
        self.volume = 0
        self.writes = []  # (reg, value) for $2004-$2007

    def read(self, reg):
        if not self.present:
            return 0x00
        if reg == 0:
            if self.data_busy:
                self.data_busy -= 1
            if self.audio_busy:
                self.audio_busy -= 1
                if not self.audio_busy:
                    self.missing = self.track not in self.tracks
            return ((0x80 if self.data_busy else 0) | (0x40 if self.audio_busy else 0) |
                    (0x20 if self.repeat else 0) | (0x10 if self.playing else 0) |
                    (0x08 if self.missing else 0) | 0x02)
        if reg == 1:
            value = tp.pattern_data_byte(self.addr)
            if not self.data_ok and self.addr == 700:
                value ^= 0x01
            self.addr += 1
            return value
        return b"S-MSU1"[reg - 2]

    def write(self, reg, value):
        if reg < 3:
            self.seek[reg] = value
        elif reg == 3:
            self.addr = self.seek[0] | self.seek[1] << 8 | self.seek[2] << 16 | value << 24
            self.data_busy = 3
        elif reg == 4:
            self.track_lo = value
        elif reg == 5:
            self.track = self.track_lo | value << 8
            self.audio_busy = 5
            self.playing = False
            self.repeat = False
        elif reg == 6:
            self.volume = value
        elif reg == 7:
            if not self.audio_busy and not self.missing:
                self.playing = bool(value & 1)
                self.repeat = bool(value & 2)
                self.play_frames = 0
        if reg >= 4:
            self.writes.append((reg, value))

    def frame(self):
        if self.playing and not self.repeat:
            self.play_frames += 1
            if self.play_frames >= self.once_frames:
                self.playing = False


class Machine:
    def __init__(self, rom, msu, buttons):
        self.rom = rom
        self.msu = msu
        self.buttons = buttons  # frame -> pad bits held that frame
        self.wram = bytearray(0x2000)
        self.colors = []
        self.cgram_latch = None
        self.frame = 0
        self.reads_4212 = 0
        self.a = self.x = self.y = self.s = self.d = 0
        self.pc = rom[0x7FFC] | rom[0x7FFD] << 8
        self.e = True
        self.flags = dict(n=0, v=0, m=1, x=1, d=0, i=1, z=0, c=0)
        self.steps = 0

    # --- memory ---
    def read8(self, addr):
        if addr < 0x2000:
            return self.wram[addr]
        if 0x2000 <= addr <= 0x2007:
            return self.msu.read(addr - 0x2000)
        if addr == 0x4212:
            # 20 reads per frame: 8 in vblank, auto-read busy for the first 2
            phase = self.reads_4212 % 20
            self.reads_4212 += 1
            if phase == 0:
                self.frame += 1
                self.msu.frame()
            in_vblank = phase < 8
            return (0x80 if in_vblank else 0) | (0x01 if phase < 2 else 0)
        if addr in (0x4218, 0x4219):
            pad = self.buttons.get(self.frame, 0)
            return pad & 0xFF if addr == 0x4218 else pad >> 8
        if addr >= 0x8000:
            return self.rom[addr - 0x8000]
        raise RuntimeError("read of $%04X at $%04X" % (addr, self.pc))

    def write8(self, addr, value):
        if addr < 0x2000:
            self.wram[addr] = value
        elif 0x2000 <= addr <= 0x2007:
            self.msu.write(addr - 0x2000, value)
        elif addr == 0x2121:
            self.cgram_latch = None
        elif addr == 0x2122:
            if self.cgram_latch is None:
                self.cgram_latch = value
            else:
                self.colors.append(self.cgram_latch | value << 8)
                self.cgram_latch = None
        elif addr in (0x2100, 0x212C, 0x212D, 0x2130, 0x2131, 0x2133, 0x4200):
            pass
        else:
            raise RuntimeError("write of $%04X at $%04X" % (addr, self.pc))

    def read(self, addr, wide):
        return self.read8(addr) | (self.read8(addr + 1) << 8 if wide else 0)

    def write(self, addr, value, wide):
        self.write8(addr, value & 0xFF)
        if wide:
            self.write8(addr + 1, value >> 8 & 0xFF)

    def fetch(self, n):
        value = 0
        for i in range(n):
            value |= self.read8(self.pc) << (8 * i)
            self.pc = (self.pc + 1) & 0xFFFF
        return value

    def push8(self, value):
        self.wram[self.s] = value
        self.s = (self.s - 1) & 0xFFFF

    def pull8(self):
        self.s = (self.s + 1) & 0xFFFF
        return self.wram[self.s]

    # --- flags ---
    def nz(self, value, wide):
        top = 0x8000 if wide else 0x80
        mask = 0xFFFF if wide else 0xFF
        self.flags["n"] = int(bool(value & top))
        self.flags["z"] = int((value & mask) == 0)

    def m16(self):
        return not self.flags["m"]

    def x16(self):
        return not self.flags["x"]

    def get_a(self):
        return self.a if self.m16() else self.a & 0xFF

    def set_a(self, value):
        if self.m16():
            self.a = value & 0xFFFF
        else:
            self.a = (self.a & 0xFF00) | (value & 0xFF)

    def compare(self, reg, operand, wide):
        mask = 0xFFFF if wide else 0xFF
        result = (reg - operand) & mask
        self.flags["c"] = int(reg >= operand)
        self.nz(result, wide)

    def set_p(self, value):
        for bit, name in zip(range(7, -1, -1), "nvmxdizc"):
            self.flags[name] = value >> bit & 1
        if self.flags["x"]:
            self.x &= 0xFF
            self.y &= 0xFF

    def p(self):
        return sum(self.flags[name] << bit for bit, name in zip(range(7, -1, -1), "nvmxdizc"))

    # --- execution ---
    def step(self):
        self.steps += 1
        pc = self.pc
        op = self.fetch(1)
        m, x = self.m16(), self.x16()
        imm_m = 2 if m else 1
        imm_x = 2 if x else 1

        def branch(cond):
            offset = self.fetch(1)
            if cond:
                self.pc = (self.pc + (offset - 256 if offset & 0x80 else offset)) & 0xFFFF

        if op == 0x78: self.flags["i"] = 1
        elif op == 0x18: self.flags["c"] = 0
        elif op == 0x38: self.flags["c"] = 1
        elif op == 0xFB:
            self.e, self.flags["c"] = bool(self.flags["c"]), int(self.e)
        elif op == 0xC2: self.set_p(self.p() & ~self.fetch(1))
        elif op == 0xE2: self.set_p(self.p() | self.fetch(1))
        elif op == 0x9A: self.s = self.x
        elif op == 0x5B: self.d = self.a; self.nz(self.a, True)
        elif op == 0x8A:
            self.set_a(self.x); self.nz(self.get_a(), m)
        elif op == 0xEB:
            self.a = ((self.a & 0xFF) << 8) | (self.a >> 8); self.nz(self.a & 0xFF, False)
        elif op == 0xE8:
            self.x = (self.x + 1) & (0xFFFF if x else 0xFF); self.nz(self.x, x)
        elif op == 0xC8:
            self.y = (self.y + 1) & (0xFFFF if x else 0xFF); self.nz(self.y, x)
        elif op == 0x60:
            lo = self.pull8(); hi = self.pull8()
            self.pc = ((hi << 8 | lo) + 1) & 0xFFFF
        elif op == 0x20:
            target = self.fetch(2)
            ret = (self.pc - 1) & 0xFFFF
            self.push8(ret >> 8); self.push8(ret & 0xFF)
            self.pc = target
        elif op == 0x4C: self.pc = self.fetch(2)
        elif op == 0xA9: self.set_a(self.fetch(imm_m)); self.nz(self.get_a(), m)
        elif op == 0xA2: self.x = self.fetch(imm_x); self.nz(self.x, x)
        elif op == 0xA0: self.y = self.fetch(imm_x); self.nz(self.y, x)
        elif op == 0xC9: self.compare(self.get_a(), self.fetch(imm_m), m)
        elif op == 0xE0: self.compare(self.x, self.fetch(imm_x), x)
        elif op == 0xC0: self.compare(self.y, self.fetch(imm_x), x)
        elif op == 0x29: self.set_a(self.get_a() & self.fetch(imm_m)); self.nz(self.get_a(), m)
        elif op == 0x49: self.set_a(self.get_a() ^ self.fetch(imm_m)); self.nz(self.get_a(), m)
        elif op in (0x69, 0xE9):
            operand = self.fetch(imm_m)
            mask = 0xFFFF if m else 0xFF
            if op == 0xE9:
                operand ^= mask
            result = self.get_a() + operand + self.flags["c"]
            self.flags["c"] = int(result > mask)
            self.set_a(result & mask); self.nz(self.get_a(), m)
        elif op == 0xAD: self.set_a(self.read(self.fetch(2), m)); self.nz(self.get_a(), m)
        elif op == 0x8D: self.write(self.fetch(2), self.get_a(), m)
        elif op == 0x9C: self.write(self.fetch(2), 0, m)
        elif op == 0x2C:
            value = self.read(self.fetch(2), m)
            top = 0x8000 if m else 0x80
            self.flags["n"] = int(bool(value & top))
            self.flags["v"] = int(bool(value & (top >> 1)))
            self.flags["z"] = int((value & self.get_a()) == 0)
        elif op == 0x2D:
            self.set_a(self.get_a() & self.read(self.fetch(2), m)); self.nz(self.get_a(), m)
        elif op == 0xBD:
            self.set_a(self.read((self.fetch(2) + self.x) & 0xFFFF, m)); self.nz(self.get_a(), m)
        elif op == 0xDD:
            self.compare(self.get_a(), self.read((self.fetch(2) + self.x) & 0xFFFF, m), m)
        elif op == 0xA5:
            self.set_a(self.read(self.d + self.fetch(1), m)); self.nz(self.get_a(), m)
        elif op == 0x85: self.write(self.d + self.fetch(1), self.get_a(), m)
        elif op == 0x64: self.write(self.d + self.fetch(1), 0, m)
        elif op == 0xC5: self.compare(self.get_a(), self.read(self.d + self.fetch(1), m), m)
        elif op == 0xD0: branch(not self.flags["z"])
        elif op == 0xF0: branch(self.flags["z"])
        elif op == 0x80: branch(True)
        elif op == 0x10: branch(not self.flags["n"])
        elif op == 0x30: branch(self.flags["n"])
        elif op == 0x70: branch(self.flags["v"])
        elif op == 0x90: branch(not self.flags["c"])
        elif op == 0xB0: branch(self.flags["c"])
        else:
            raise RuntimeError("opcode %02X at $%04X" % (op, pc))

    def run_frames(self, frames, max_steps=5_000_000):
        while self.frame < frames:
            pc = self.pc
            self.step()
            if self.pc == pc:
                return  # halted: a branch to itself
            if self.steps > max_steps:
                raise RuntimeError("stuck at $%04X" % self.pc)


def run(name, msu, buttons, frames, expect_colors, expect_writes=None, expect_volume=None):
    rom = tp.test_rom()
    machine = Machine(rom, msu, buttons)
    machine.run_frames(frames, max_steps=2_000_000 + 20_000 * frames)
    ok = machine.colors == expect_colors
    if expect_writes is not None:
        ok = ok and msu.writes == expect_writes
    if expect_volume is not None:
        ok = ok and msu.volume == expect_volume
    names = {v: k for k, v in dict(grey=tp.GREY, red=tp.RED, magenta=tp.MAGENTA,
                                   yellow=tp.YELLOW, green=tp.GREEN, blue=tp.BLUE,
                                   white=tp.WHITE, cyan=tp.CYAN).items()}
    shown = [names.get(c, hex(c)) for c in machine.colors]
    print("%-4s %-22s colours %s" % ("ok" if ok else "FAIL", name, " ".join(shown)))
    if not ok:
        print("     writes", ["$%04X=%02X" % (0x2000 + r, v) for r, v in msu.writes])
        print("     expected colours", [names.get(c, hex(c)) for c in expect_colors])
        if expect_writes is not None:
            print("     expected writes", ["$%04X=%02X" % (0x2000 + r, v) for r, v in expect_writes])
    return ok


def main():
    g = tp
    results = [
        run("no MSU-1", MSU(present=False), {}, 10, [g.GREY, g.RED]),
        run("bad data", MSU(data_ok=False), {}, 10, [g.GREY, g.MAGENTA]),
        run("track 1 missing", MSU(tracks=(2,)), {}, 10, [g.GREY, g.YELLOW],
            [(4, 1), (5, 0)]),
        run("track 1 plays", MSU(), {}, 10, [g.GREY, g.GREEN],
            [(4, 1), (5, 0), (6, 0xFF), (7, 3)]),
        run("buttons", MSU(once_frames=20), {
            10: tp.PAD_B,                    # track 2, once; grey when it ends
            40: tp.PAD_A,                    # track 1
            45: tp.PAD_X,                    # pause with resume
            50: tp.PAD_X,                    # resume
            55: tp.PAD_UP,                   # volume stays at FF
            60: tp.PAD_DOWN, 61: tp.PAD_DOWN,  # held: one step
            65: tp.PAD_DOWN,                 # second step
            70: tp.PAD_Y,                    # stop
        }, 80,
            [g.GREY, g.GREEN, g.BLUE, g.GREY, g.GREEN, g.WHITE, g.GREEN, g.GREY],
            [(4, 1), (5, 0), (6, 0xFF), (7, 3),
             (4, 2), (5, 0), (6, 0xFF), (7, 1),
             (4, 1), (5, 0), (6, 0xFF), (7, 3),
             (7, 4),
             (4, 1), (5, 0), (6, 0xFF), (7, 3),
             (6, 0xFF), (6, 0xDF), (6, 0xBF),
             (7, 0)], expect_volume=0xBF),
        run("track 2 missing", MSU(tracks=(1,)), {10: tp.PAD_B}, 20,
            [g.GREY, g.GREEN, g.YELLOW]),
        run("track 3 (analysis)", MSU(once_frames=20), {10: tp.PAD_R}, 40,
            [g.GREY, g.GREEN, g.CYAN, g.GREY],
            [(4, 1), (5, 0), (6, 0xFF), (7, 3), (4, 3), (5, 0), (6, 0xFF), (7, 1)]),
    ]
    if all(results):
        print("PASS: test ROM")
        return 0
    print("FAIL: test ROM")
    return 1


if __name__ == "__main__":
    sys.exit(main())
