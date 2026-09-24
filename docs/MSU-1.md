# MSU-1 on the Analogue Pocket: feasibility and implementation plan

Status: phase 0 (the probe build) has run on a Pocket with firmware 2.7 and
answered every open question; see [Phase 0 results](#phase-0-results-firmware-27).
Phase 1 (MSU-1 audio and a 192 KB data port) is implemented as the beta core
`andr3a5n.SNESMSU` and passes simulation; it waits for its first hardware
test. How to build, install and test it: [MSU-1-beta.md](MSU-1-beta.md).

## Verdict

MSU-1 audio is feasible on the Pocket with the current openFPGA firmware. The
core-side MSU-1 logic is already in this repository and needs no changes. What
is missing is the part that MiSTer does in software on its ARM processor:
finding the files, opening them and feeding the audio to the core. On the
Pocket the FPGA has to do that itself, using the APF target commands `0x0190`,
`0x0192` and `0x0180`. The phase 0 probe confirmed on real hardware that these
commands behave as documented, that the firmware reports each opened file's
exact size, and that reads reach 831 KB/s in 4 KB pieces and 1.7 MB/s in 64 KB
pieces. MSU-1 audio needs 176.4 KB/s.

The data port (the `.msu` file) is feasible for files that fit in spare SDRAM
(up to 16 MB). Video hacks that stream hundreds of megabytes through the data
port at DMA speed are not realistic with the measured bandwidth. They are out of
scope.

The largest risk is not bandwidth, it is FPGA space. Measured: the `main`
bitstream (CX4 + GSU + SA-1 + DSPn) already uses 97% of the logic, so MSU-1
cannot simply be added to it. [Fitting the logic](#fitting-the-logic) describes
how to keep every enhancement chip anyway, by splitting `main` into one
bitstream per chip.

## Starting point

### This repository

Before phase 1:

| Piece | State |
|---|---|
| `rtl/upstream/chip/MSU1/` (`MSU.sv`, `msu_audio.v`, `msu_data_store.sv`, `msu_fifo.v`) | Present, byte-identical to `SNES_MiSTer/rtl/chip/MSU1/`, listed in `chip.qip` |
| `rtl/upstream/main.v` | Instantiates `MSU` under `USE_MSU` and muxes `MSU_DO` onto the CPU data bus (`if(MSU_SEL) DI = MSU_DO;`) |
| `generate.tcl`, `projects/snes_pocket.qsf` | `USE_MSU '0` in every build |
| `rtl/mister_top/SNES.sv` | `.MSU_ENABLE(0)`, MSU ports commented out, the MiSTer MSU section kept as comments |
| `target/pocket/core_bridge_cmd.v` | Implements target commands `0x0180`, `0x0184`, `0x0190` and `0x0192` |
| `target/pocket/core_top.sv` | Leaves every `target_dataslot_*` input unconnected; ties the 256 KB SRAM idle |

So the SNES side of MSU-1 (registers `$2000-$2007`, the 44.1 kHz player, loop
and resume handling, the data-port reader) is already written and maintained
upstream. The Pocket work is glue only. The upstream files can stay untouched,
which keeps the Copybara sync working.

### How MiSTer does it

On MiSTer, `rtl/hps_ext.v` connects the core to `Main_MiSTer` running on the
ARM. The ARM does all file work:

| Core → ARM | ARM → core |
|---|---|
| `msu_track_request` + `msu_track_num` (opcode `0x35`) | Opens `<rom>-<n>.pcm`, returns its size (`0` means missing) |
| `msu_audio_seek` + `msu_audio_sector` (opcode `0x36`) | Streams 1024-byte sectors through `ioctl` index 2 |
| `msu_audio_req` (opcode `0x34`) | Streams the next 1024-byte sector |
| (at load) | `msu_enable`; loads `<rom>.msu` into DDR3 at `msu_data_base` |

`msu_audio.v` keeps only a 1024-dword FIFO (about 23 ms) and asks for one
sector at a time. That works because the ARM answers in microseconds from the
Linux page cache. On the Pocket each read is a target command with milliseconds
of latency, so the Pocket glue needs a much deeper buffer of its own.

### The other repositories

- **HarpMudd.mp3player** is the key precedent. A soft RISC-V drives
  `0x0190`/`0x0192`/`0x0180` at runtime and streams from SD. Hardware results
  it documents:
  - 736 KB/s sequential throughput with 4 KB reads (`docs/FLAC.md`).
  - Random-offset reads cost about 24 ms each, because APF re-walks the FAT
    cluster chain (480 ms for about 20 reads).
  - `target_dataslot_done` stays high until the *next* command is accepted. A
    reader that samples it too early sees the previous command's completion
    (`src/fpga/core/tgt_cmd.v` has the fix).
  - APF keeps its `{slot_id, size}` table at the start of the datatable BRAM
    (words 0-63). The `0x0190`/`0x0192` structs must live above it; HarpMudd
    uses `0xF8002100` and `0xF8002200` (`src/fpga/core/core_game.vh`).
  - A core-initiated `0x0192` raises no `0x008A`, so the core is not told the
    new file's size.
  - Switching reads between slots drops APF's seek cache.
  - `0x0192` into an initially empty `deferload` slot works.
- **pocket-mp3** copies the whole file into SDRAM at load time and does no
  runtime streaming. That model does not fit MSU-1: a pack is often 30-100 PCM
  files of 10-60 MB each. Its MIT-licensed 44.1→48 kHz polyphase resampler
  (`src/fpga/resampler.sv`) is a candidate for the polish phase.
- **timboettiger/openfpga-SNES-pro-action-replay-mk3** lists MSU-1 in its
  README, but it is not implemented there: `USE_MSU` is `'0` in every build and
  `hps_ext.v` is not used. Nothing to reuse for MSU-1. It does show that adding
  extra data slots to this core is unproblematic.

The official APF documentation for the commands this plan uses:

| Command | Use here | Relevant result codes |
|---|---|---|
| `0x0190` Get filename | Full path of the ROM in slot 0, e.g. `/Assets/snes/common/MSU/Zelda/zelda.sfc` | 0 ok, 1 slot not defined |
| `0x0192` Open file into slot | Open `<base>-<n>.pcm` / `<base>.msu` by path. Struct: 256-byte path, flags at `+0x100`, size at `+0x104` | 0 ok, **3 file not found**, 4 malformed path |
| `0x0180` Read | Read `length` bytes at `offset` into a bridge address | 0 ok, **2 error or out of range**; length `0xFFFFFFFF` is clamped to the end of the file |

## Budget

Measured by the phase 0 probe on a Pocket with firmware 2.7 (see
[Phase 0 results](#phase-0-results-firmware-27)):

| Quantity | Value |
|---|---|
| MSU-1 PCM (44.1 kHz, 16-bit stereo) | 176.4 KB/s |
| Sequential read, 4 KB / 16 KB / 64 KB per command | 831 / 1,379 / 1,712 KB/s |
| Cost of one read | ~1.6 ms fixed + ~2 MB/s transfer |
| Read at a new offset in the same file (seek) | 4-7 ms for 4 KB |
| Read after switching to another open file | 17-27 ms for 4 KB |
| Opening a file by path | 8-28 ms; a missing file answers in 12 ms |
| MSU-1 data port, CPU DMA from `$2001` | up to 2.68 MB/s, more than APF delivers, so the data file must come from RAM |
| `msu_audio` internal FIFO | 4 KB = 23 ms |

Free memory the SNES core does not use on the Pocket:

- **SRAM, 256 KB, async, dedicated pins.** Tied idle in `core_top.sv`. It is the
  natural audio buffer, because it shares nothing with the SNES memory system.
- **SDRAM port 1 (banks 2-3, 16 MB).** On MiSTer this port holds WRAM. The
  Pocket port moved WRAM to PSRAM, so port 1 is tied off. This is where large
  `.msu` data files can go (phase 2).
- **PSRAM second dies.** Unused, but they share the bus with WRAM and ARAM. Not
  proposed.

## Architecture

```
               clk_74a                                         clk_sys (21.477 / 21.281 MHz)
APF ─bridge─► core_bridge_cmd ◄─► msu_host ◄──── toggles ────► msu_shim ◄─► MAIN_SNES
                   │ datatable       │ 0190/0192/0180                │        ├─ main ─ MSU.sv ($2000-$2007)
                   │ (paths, sizes)  │ queue + preload               │        ├─ msu_audio.v ─► mixer ─► audio
bridge_wr 0x3xxxxxxx ──────────────► msu_sram (256 KB SRAM) ─ sector words ─ CDC FIFO ─┘        └─ msu_data_store.sv
                                            └──────────────── 64-bit data reads (CDC) ─────────────┘
```

New Pocket-only modules go in `target/pocket/msu/`. Nothing under
`rtl/upstream/` changes. `MAIN_SNES` gets the parts MiSTer's `SNES.sv` has:
`msu_audio`, `msu_data_store` and the mixer.

1. **`msu_tgt_cmd.sv`** (phase 0): one target command at a time, with the
   `done` fix and a timeout.
2. **`msu_path.sv`** (phase 0): `<name>.msu` / `<name>-<n>.pcm` from the ROM's
   path, in the `0x0192` parameter struct.
3. **`msu_host.sv` (clk_74a).** Replaces the ARM: detection and data file
   preload at boot, opening tracks, the audio sector queue, serving sectors. A
   hardware state machine, not a soft CPU, to save space.
4. **`msu_sram.sv`.** Async SRAM controller for three clients: bridge writes
   (the data of `0x0180` reads, landing at `0x3xxxxxxx`), the sector reader and
   the data port.
5. **`msu_pocket.sv`.** The top of the above, and the shim (clk_sys) that
   presents exactly the `hps_ext.v` contract to `main` and `msu_audio`:
   `msu_enable`, `track_mounting`, `track_missing`, `audio_size`, `audio_ack`,
   and the `audio_download` window carrying 512 16-bit words per sector.
   Requests cross to clk_74a as toggles, sector data through a dual-clock
   FIFO, data port reads as a toggle handshake with `msu_data_store`.

`core_top.sv` instantiates `msu_pocket` when its `MSU` parameter is set, and
`MAIN_SNES` has `msu_audio`, `msu_data_store` and the mixer under `USE_MSU`,
connected through its `msu_*` ports.

### SRAM layout

| SRAM range | Use |
|---|---|
| `0x00000-0x0FFFF` (64 KB) | Audio sector queue: 64 slots of 1 KB, each tagged with its sector number in the file |
| `0x10000-0x3FFFF` (192 KB) | The start of the `.msu` data file, preloaded at boot |

### Sequences

**Boot.** The loader lets the SNES run before APF has finished, so a game that
checks for `S-MSU1` in its reset handler would miss MSU-1 for the whole
session. The SNES is held in reset until detection finishes (the probe
already does this):

1. Wait for `reset_n` from `core_bridge_cmd`.
2. `0x0190` on slot 0 → the ROM's path. The first command after the release
   took 205 ms on hardware; each command times out after 3 s, after which the
   game boots without MSU-1.
3. Build `<name>.msu`, `0x0192` it into its slot. Result 0 → MSU-1 on, and the
   datatable now holds its exact size. Any other result → try
   `<name>-1.pcm`: if that opens, MSU-1 is on with an empty data file,
   otherwise off. The MSU-1 rule is that the data file must exist and may be
   empty; the fallback covers a firmware that refuses 0-byte files, which the
   probe did not test.
4. Preload up to 192 KB of it into SRAM with 64 KB reads (about 0.1 s).
5. Release the SNES.

**Track mount** (the game writes `$2004/$2005`, so `track_request` rises):

1. The shim raises `track_mounting`, which keeps the audio-busy bit set. Games
   poll that bit (FXPAK has this latency too).
2. Build `<name>-<n>.pcm`, `0x0192` into the audio slot (about 10 ms).
   Result 3 → `track_missing`, and the game falls back to SPC music.
3. Take the exact size from the datatable, read the first 16 KB, take the loop
   point from bytes 4-7 and compute its sector `(loop + 2) >> 8`, exactly as
   `msu_audio` does.
4. Report the size and drop `track_mounting`. Mounting takes about 20 ms.

**Streaming.** The queue holds sectors in playback order, not file order. The
host reads 16 KB at a time (about 10 ms each, 8 times faster than playback)
from the current position to the end of the file, then continues at the loop
sector. When `msu_audio` reaches the end and seeks to the loop sector, that
sector is already at the head of the queue: loops need no read and are
gapless. A request for any other sector (resume, a game's own seek) flushes
the queue and reads from there; the first 4 KB arrive in 4-7 ms, inside the
17-23 ms `msu_audio` still has buffered. The 64 KB queue is 371 ms of audio,
nine times the slowest read measured. The file's last sector is padded to 1 KB;
`msu_audio` stops at the exact size anyway.

### Package changes

- A new beta core, `andr3a5n.SNESMSU`, until MSU-1 is proven, so the normal core
  stays as it is.
- `data.json`: Cartridge, Save, then "MSU-1 Audio" (id 20) and "MSU-1 Data"
  (id 21), both `"deferload": true`, `"required": false`, parameters `0x8`.
  Their datatable size words are at slot index 2 and 3.
- `generate.tcl`: one bitstream per chip, see [Fitting the logic](#fitting-the-logic).
- `support/loader.asm`: pick the bitstream by chip type.

Users lay out a pack like this and pick the `.sfc` in the Pocket browser. The
browser only lists `smc`/`sfc`/`bs`, so the other files stay hidden:

```
/Assets/snes/common/MSU-1/Zelda3/zelda3.sfc
/Assets/snes/common/MSU-1/Zelda3/zelda3.msu
/Assets/snes/common/MSU-1/Zelda3/zelda3-1.pcm ... zelda3-34.pcm
```

## Data port (`.msu` file)

Phase 1 preloads the first 192 KB of the data file into SRAM and serves `$2001`
from there through the unchanged `msu_data_store.sv`. Music-only packs, the
large majority, have an empty or small data file. Reads beyond 192 KB return
zeros; seeks still complete, so no game waits forever.

Phase 2, for larger data files:

- Preload into SDRAM port 1 (banks 2-3, up to 16 MB) with 64 KB reads, about
  0.6 s per MB. The preload runs before the first track opens: interleaving
  data reads with audio reads would cost 17-27 ms per switch.
- A seek beyond the preload watermark holds `data_ack` low (the busy bit stays
  set) until the data is in.
- Port-1 requests must follow the bus-cycle timing MiSTer uses for WRAM
  (issued on `SYSCLKR_CE`/`SYSCLKF_CE`). The controller restarts its slot
  counter on port-1 requests, so arbitrary timing could disturb ROM reads on
  port 0. This needs simulation with the SA-1 and GSU builds before hardware.
- A `.msu` larger than 16 MB (video hacks) is not supported. MSU-1 stays
  enabled for audio and the data port serves the first 16 MB.

## Fitting the logic

Measured with Quartus 21.1 (the CI image), unmodified `main` bitstream (NTSC,
CX4 + GSU + SA-1 + DSPn):

| Resource | Used | Free |
|---|---|---|
| Logic (ALMs) | 17,878 / 18,480 (97%) | ~600 |
| M10K blocks | 257 / 308 (83%) | 51 |
| DSP blocks | 24 / 66 | 42 |

Timing: the unmodified core already reports negative setup slack on the SNES
clocks (-6.7 ns on the 21.48 MHz system clock, -3.4 ns on the 85.9 MHz memory
clock). Much of that is multicycle paths the constraints do not describe:
`target/pocket/core_constraints.sdc` sets its multicycle paths on
`ic|nes|sdram|*`, an instance that does not exist in this core, so Quartus
ignores them. The released core works regardless. New logic is judged against
this baseline, not against zero slack.

Estimate for MSU-1 itself:

| Block | ALMs | M10K | DSP |
|---|---|---|---|
| Upstream `MSU.sv` + `msu_audio.v` + `msu_fifo` | 400-600 | 4 | 2 |
| `msu_apf_ctrl` + `msu_path` + `msu_sram` + shim + CDC | 500-900 | 1-2 | 0 |
| Mixer | ~40 | 0 | 0 |
| Phase 2: `msu_data_store` + port-1 adapter + loader FIFO | 250-400 | 1-2 | 0 |
| **Total** | **~1,200-1,900** (7-10% of 18,480) | **6-8** | **2** |

The audio ring is in SRAM because block RAM is tight. VRAM (64 KB) and BSRAM
(128 KB) alone take about 192 of the 308 M10K blocks.

So MSU-1 does not fit into `main` next to all four chips. Removing chips
would cost classics (Mega Man X2/X3, Super Mario Kart, Super Mario RPG, Star
Fox and Yoshi's Island all have popular MSU-1 packs). Instead, split `main` by
chip. The chip32 loader already reads the chip type from the ROM header and
picks between three bitstreams, and the same mechanism can pick between more:

| Bitstream | Chips | For |
|---|---|---|
| plain + MSU-1 | none (DSPn too if it fits) | most games and most MSU-1 packs |
| SA-1 + MSU-1 | SA-1 | Super Mario RPG, Kirby Super Star |
| GSU + MSU-1 | Super FX | Star Fox, Yoshi's Island, Doom |
| CX4 + DSPn + MSU-1 | CX4, DSP-1..4 | Mega Man X2/X3, Super Mario Kart, Pilotwings |
| SPCSDD1 (as today) | SPC7110, S-DD1, BS-X | unchanged, MSU-1 if it fits |
| PAL (as today) | all four | PAL ROMs; a PAL plain + MSU-1 variant if needed |

Each of these has far more headroom than today's `main`, and no game loses its
chip. Measured on the probe build, which has no coprocessors: the SNES itself
(`MAIN_SNES`) takes about 8,900 ALMs and the whole bitstream 12,731 (69%), of
which the probe is about 2,800. A plain bitstream therefore leaves roughly
8,000 ALMs for MSU-1, and the phase 0 pieces phase 1 reuses (`msu_tgt_cmd`,
`msu_path`) are about 315 of them. The cost is CI time (one compile of about 35 minutes each, in parallel)
and a larger download. Only if a combination still does not fit does a
rarely used chip or an optional feature go.

Phase 1 settled on three MSU-1 bitstreams: DSP-n and CX4 together (the
default), SA-1, and Super FX. SPCSDD1 and PAL stay as they are, without
MSU-1. Measured with Quartus 21.1 (`msu` locally, `msu_sa1` and `msu_gsu` in
CI run 2 of the MSU-1 Beta workflow):

| | `msu` (DSP-n, CX4) | `msu_sa1` (SA-1) | `msu_gsu` (Super FX) | `main` today (four chips, no MSU-1) |
|---|---|---|---|---|
| Logic (ALMs) | 14,953 (81%) | 14,630 (79%) | 13,804 (75%) | 17,878 (97%) |
| RAM blocks (of 308) | 262 | 213 | 212 | 257 |
| DSP blocks | 22 | 21 | 23 | 24 |
| Worst setup slack, clk_sys / clk_mem | -4.8 / -2.7 ns | -6.0 / -2.8 ns | -3.8 / -2.4 ns | -6.7 / -3.4 ns |
| Worst setup slack, clk_74a | +2.2 ns | +1.7 ns | +1.9 ns | |
| Hold | positive | positive | positive | |

MSU-1 itself takes about 1,780 ALMs: `msu_pocket` (host, SRAM, clock
crossing) 1,334, `msu_audio` 234, `msu_data_store` 131, `MSU` 81. None of
the 2,000 worst failing paths on either SNES clock touches MSU-1 logic; the
violations are the core's own, as in the baseline; every MSU-1 bitstream
stays inside the slack `main` is released with. The normal `ntsc` build
synthesises to exactly the same registers, memory and DSP use as before
phase 1.

## Phase 0 results (firmware 2.7)

The probe ran on a Pocket with firmware 2.7 against the generated test set.
The log is in [probe-results/fw2.7.msulog](probe-results/fw2.7.msulog);
`python3 tools/msu_probe.py decode docs/probe-results/fw2.7.msulog` prints the
full report. Every read matched the test pattern.

| # | Question | Answer | Consequence for phase 1 |
|---|---|---|---|
| P1 | Does `0x0190` on slot 0 return the ROM's path? | Yes, the full path at offset 0, e.g. `/Assets/snes/common/msuprobe/msuprobe.sfc`, in 0.5 ms | File names are derived from it as planned |
| P2 | Does `0x0192` open a file into a non-reloadable (`0x8`) deferload slot? | Yes. 8-28 ms per open, 11 ms for the 100th file of a folder. A missing file returns 3 | Slots use `0x8` and stay out of the menu; mounting a track takes about 20 ms |
| P3 | Is the size of a core-opened file reported? | Yes: after each `0x0192`, APF writes `{slot id, exact size}` into the datatable at the slot's position in `data.json` | No end-of-file probing: the size is read after the open |
| P4 | Reads at the end of a file | A read crossing the end returns 2 and no data. Length `0xFFFFFFFF` returns the exact tail (1,236 bytes) | The last read is sized from the known file size |
| P5 | Read speed | 831 KB/s at 4 KB, 1,115 at 8 KB, 1,379 at 16 KB, 1,572 at 32 KB, 1,712 at 64 KB. Scattered 4 KB reads: 4-7 ms | 16 KB audio reads; a seek costs less than `msu_audio`'s own buffer |
| P6 | Alternating reads between two open files | 17-27 ms per read instead of 4 ms | Preload the data file; never interleave it with audio |
| P7 | Boot | APF released the core 752 ms after PLL lock; the first command took 205 ms, later ones are fast | 2 s timeout for detection |
| P8 | Firmware | Works on 2.7 | Tested version noted in the README |

Two more facts from the run:

- The bridge is big-endian on firmware 2.7 (`bridge_endian_little` = 0): in a
  32-bit bridge word, the first file byte is bits 31-24. The core handles both
  orders, like `data_loader.sv`.
- The extra nonvolatile slot was saved to the SD card on exit, even though
  the chip32 loader found no file to load into it at boot.

## Phased plan

**Phase 0: probe build (implemented).** A separate core,
`andr3a5n.SNESMSUProbe`, so the normal SNES core stays untouched:

- `target/pocket/msu/msu_tgt_cmd.sv`: issues one target command at a time,
  with the `done` fix and a 10 s timeout. Reused by phase 1.
- `target/pocket/msu/msu_path.sv`: builds `<name>.msu` / `<name>-<n>.pcm` in
  the `0x0192` parameter struct from the `0x0190` response. Reused by phase 1.
- `target/pocket/msu/msu_probe.sv`: the test sequence, a 4 KB log exposed at
  bridge `0x5000_0000` as data slot 30, and a read sink at `0x6xxxxxxx` that
  counts and pattern-checks the data APF delivers.
- `target/pocket/msu/msu_probe_overlay.sv`: 32x28 text overlay with the results.
- `core_top.sv`: all of it behind the `MSU_PROBE` parameter; normal builds are
  unchanged. The SNES is held in reset until the probe is done and START is
  pressed.
- `sim/msu/`: testbench running the probe against the real `core_bridge_cmd.v`
  and a model of the firmware that serves the generated test files.
- `tools/msu_probe.py`: test file generator, log decoder, ROM generator.
- `.github/workflows/msu_probe.yml`: simulate, compile, package for the SD card.

Done: answered P1-P8 in one hardware session.

**Phase 1: audio MVP (implemented, waiting for hardware).** `msu_host`,
`msu_sram`, `msu_pocket`, `msu_audio` and the mixer in `MAIN_SNES`, the data
file preload into SRAM, per-chip bitstreams, as a beta core
`andr3a5n.SNESMSU` ([MSU-1-beta.md](MSU-1-beta.md)). Verified before
hardware:

- `sim/msu/tb_msu_play.sv`: the firmware model (`apf_model.svh`, shared with
  the probe testbench) serves `0x0190`/`0x0192`/`0x0180` from files on disk,
  with the bridge paced like the real SPI link. Stubs for the Altera `dcfifo`
  and the VHDL `CEGen`. `msu_audio` runs at 10 times the real sample rate,
  which puts 10 times the real load on the stream.
- Checked bit-exact against the `.pcm` samples: data port reads (including the
  end of the file), a missing track, a looping track with the loop point in
  the middle and a queue smaller than the track, a 5 ms firmware stall (50 ms
  at the real rate), a track change during playback, a track played once and
  replayed (loop point 0), resume, and MSU-1 detection without a `.msu` file.
- Not covered: loop points past 64 KB (sector numbers are 22 bits wide
  throughout, as upstream) and stalls longer than the queue (371 ms).
- The simulation found a race in the queue bookkeeping (a read issued before
  the previous one was counted, which overfilled the queue) and two
  `msu_audio` behaviours that MiSTer shares, now documented in
  [MSU-1-beta.md](MSU-1-beta.md#what-works-and-what-does-not).
- `sim/msu/check_testrom.py` runs the hardware test ROM in a 65816
  interpreter against a model of the MSU-1 registers.

Hardware: the test ROM, several real packs, long play, and loop points by
ear.

**Phase 2: data port.** SDRAM port-1 preload and the `msu_data_store` adapter,
simulated against the port-0 ROM traffic of the SA-1/GSU builds. Hardware: a
pack that reads the data port.

**Phase 3: polish.**

- Core Settings: MSU-1 on/off and an MSU volume trim (`interact.json`).
- Optional 44.1→48 kHz resampling of the MSU path. Today `sound_i2s` picks the
  newest sample at 48 kHz (zero-order hold); pocket-mp3's resampler is a
  starting point.
- README section, release.

## Side finding: SDRAM is never refreshed

Deferred: the owner decided to leave this as it is until MSU-1 works, since
nothing about MSU-1 depends on it. Unrelated to MSU-1, but found while checking SDRAM port 1. Since upstream
commit `b633108` ("sdram: synchronise refresh with WRAM refresh"),
`rtl/upstream/sdram.sv` only issues auto-refresh when `rfs1` is high
(`rfs <= ~raw_req_test & rfs1`). MiSTer drives it with
`.rfs1(... !RESET_N ? RESET_REFRESH : SNES_REFRESH)` from `main`'s `REFRESH`
output. `rtl/mister_top/SNES.sv` ties `.rfs1(1'b0)` and leaves `.REFRESH()`
open (commit `fabb62d`). So the Pocket build never refreshes SDRAM, and ROM rows
the game does not touch often rely on the cells holding their charge. The likely
symptom is rare, time-dependent corruption in large ROMs. The fix mirrors
MiSTer: connect `.REFRESH(SNES_REFRESH)` and drive
`.rfs1(RESET_N ? SNES_REFRESH : RFSH)`.
