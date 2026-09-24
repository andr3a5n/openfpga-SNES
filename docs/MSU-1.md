# MSU-1 on the Analogue Pocket: feasibility and implementation plan

Status: phase 0 (the probe build) is implemented and simulated, and waits for a
run on real hardware. See [MSU-1-probe.md](MSU-1-probe.md) for how to run it.

## Verdict

MSU-1 audio is feasible on the Pocket with the current openFPGA firmware. The
core-side MSU-1 logic is already in this repository and needs no changes. What
is missing is the part that MiSTer does in software on its ARM processor:
finding the files, opening them and feeding the audio to the core. On the
Pocket the FPGA has to do that itself, using the APF target commands `0x0190`,
`0x0192` and `0x0180`. The HarpMudd MP3 player has shown on real hardware that
these commands work and that sequential SD reads reach about 736 KB/s. MSU-1
audio needs 176.4 KB/s.

The data port (the `.msu` file) is feasible for files that fit in spare SDRAM
(up to 16 MB). Video hacks that stream hundreds of megabytes through the data
port at DMA speed are not realistic with the measured bandwidth. They are out of
scope.

The largest risk is not bandwidth, it is FPGA space. Measured: the `main`
bitstream (CX4 + GSU + SA-1 + DSPn) already uses 97% of the logic, so MSU-1
cannot simply be added to it. [Fitting the logic](#fitting-the-logic) describes
how to keep every enhancement chip anyway, by splitting `main` into one
bitstream per chip.

## What exists today

### This repository

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

| Quantity | Value |
|---|---|
| MSU-1 PCM (44.1 kHz, 16-bit stereo) | 176.4 KB/s |
| Measured sequential APF read, 4 KB chunks | 736 KB/s → 24% duty cycle |
| Random read (seek, loop jump) | ~24 ms |
| MSU-1 data port, CPU DMA from `$2001` | up to 2.68 MB/s. Higher than APF can deliver, so the data file must come from RAM |
| `msu_audio` internal FIFO | 4 KB = 23 ms |
| Proposed main ring in SRAM | 128 KB = 743 ms |
| Proposed loop-point cache in SRAM | 64 KB = 371 ms |

Free memory the SNES core does not use on the Pocket:

- **SRAM, 256 KB, async, dedicated pins.** Tied idle in `core_top.sv`. It is the
  natural audio buffer, because it shares nothing with the SNES memory system.
- **SDRAM port 1 (banks 2-3, 16 MB).** On MiSTer this port holds WRAM. The
  Pocket port moved WRAM to PSRAM, so port 1 is tied off. This is where the
  `.msu` data file can go.
- **PSRAM second dies.** Unused, but they share the bus with WRAM and ARAM. Not
  proposed.

## Architecture

```
                clk_74a                                         clk_sys (21.477 / 21.281 MHz)
 APF ─bridge─► core_bridge_cmd ◄─► msu_apf_ctrl ◄──CDC──► msu_host_shim ◄─► main (upstream)
                    │ datatable        │  0190/0192/0180            │           └─ MSU.sv  ($2000-$2007)
                    │ (path structs)   │                            │
                    │                  ▼                            ├─► msu_audio.v (upstream) ─► mixer ─► sound_i2s
 bridge_wr 0x3xxxxxxx ──► msu_sram (arbiter + async SRAM, 256 KB)   │
                                       └── sector reader ──CDC FIFO─┘
                                                                  (phase 2: msu_data_store.sv ◄─► SDRAM port 1)
```

New Pocket-only modules go in `target/pocket/msu/`. Nothing under
`rtl/upstream/` changes.

1. **`msu_apf_ctrl.sv` (clk_74a).** Replaces the ARM. It owns the
   `target_dataslot_*` interface of `core_bridge_cmd` (tied off today). It
   issues one command at a time and uses HarpMudd's rule of waiting for `done`
   to go low before waiting for it to go high. It runs detection at boot,
   opens tracks, keeps the ring full, and finds end of file. It is a hardware
   FSM, not a soft CPU: a soft CPU would cost roughly 1,000 ALMs and several
   M10K blocks on a device the SNES already fills.
2. **`msu_path.sv`.** Builds file paths in the datatable BRAM. It copies the
   `0x0190` response for slot 0 (at word 64) to the `0x0192` parameter struct
   (at word 128). The copy stops at the last `.` after the last `/`, then
   appends `-<n>.pcm` (decimal track number, no leading zeros) or `.msu` and a
   NUL, and clears the flags and size words. It arbitrates the core-side
   datatable port with the existing save-size writer in `core_top.sv`. Paths
   that would exceed 255 bytes count as "not found".
3. **`msu_sram.sv`.** Controller for the async SRAM with two clients: bridge
   writes (`0x0180` data landing at `0x3000_0000-0x3003_FFFF`) and the sector
   reader. It also counts the words each `0x0180` delivers. That count is how
   end of file is found.
4. **`msu_host_shim.sv` (clk_sys).** Presents exactly the `hps_ext.v` signal
   contract to `main` and `msu_audio`: `msu_enable`, `track_mounting`,
   `track_missing`, `audio_size`, `audio_ack`, and the `audio_download` window
   carrying 512 16-bit words per sector. Requests cross to clk_74a as toggles;
   sector data crosses through a small dual-clock FIFO.
5. **Mixer in `rtl/mister_top/SNES.sv`.** A saturating add of the SNES and MSU
   audio, copied from MiSTer's `SNES.sv`.

### SRAM layout

| SRAM range | Use |
|---|---|
| `0x00000-0x1FFFF` (128 KB) | Main ring. Holds file bytes `[lo, hi)`; position = file offset mod 128 KB |
| `0x20000-0x2FFFF` (64 KB) | Loop-point cache: file bytes from the loop sector onward |
| `0x30000-0x3FFFF` (64 KB) | Spare (phase 1). Candidate data-file cache for very small `.msu` files |

### Sequences

**Boot / ROM load.** The loader drops `ioctl_download` before APF has finished,
so the SNES would start running before detection completes. A game that checks
for `S-MSU1` in its reset handler would then fall back to SPC music for the
whole session. So the SNES is held in reset (a new term in `reset` in
`SNES.sv`, like MiSTer's `msu_data_download`) until detection finishes:

1. Wait for `reset_n` from `core_bridge_cmd` (APF has left reset).
2. `0x0190` on slot 0 → path of the ROM.
3. Build `<base>.msu`, `0x0192` into slot 21.
4. Result 0 → `msu_enable = 1`; result 3 → MSU-1 off. That is the MSU-1 rule
   (the data file must exist, it may be empty).
5. Release reset. If nothing answers within about 1 s, give up with MSU-1 off,
   so a firmware without these commands still boots games normally.

**Track mount** (the game writes `$2004/$2005`, so `track_request` rises):

1. The shim raises `track_mounting`, which keeps the audio-busy bit set. Games
   poll that bit, so this latency is expected (FXPAK has it too).
2. Build `<base>-<n>.pcm`, `0x0192` into slot 20.
   - Result 3 → `track_missing = 1`, size 0. The game falls back to SPC for
     that track.
3. Read the first chunk into the ring. Parse bytes 4-7 (loop point, in samples)
   and compute loop sector `(loop + 2) >> 8`, exactly as `msu_audio` does.
4. Report size (see below) and drop `track_mounting`.
5. In the background: fill the loop cache from the loop sector, then keep the
   ring topped up.

**Streaming.** For each `audio_req` or `audio_seek` for sector `s`, the shim
serves the 1024 bytes from the loop cache if `s` falls in it, else from the
ring if `s*1024` is in `[lo, hi)`, and only then raises `audio_ack` and streams
512 words. A miss (resume or an unusual seek) flushes the ring, restarts
reading at `s*1024`, and serves once data lands (about 25-50 ms of silence, like
real hardware). Read priority: miss > ring below low watermark > loop cache
fill > ring top-up.

**Loops.** At end of file `msu_audio` seeks to the loop sector. That sector is
already in the loop cache, so the loop is gapless. The cache covers 371 ms
while the ring restarts from `loop + 64 KB` with one random read.

**End of file and size.** The core is not told a file's size after `0x0192`.
Until end of file is known, the shim reports a provisional size of
`0xFFFF_FFFF`. `msu_audio` reads `track_size` combinationally, so updating it
later works without touching upstream code. The controller counts the words each
read delivers:

- A read that returns fewer words than asked, or fails with code 2, has crossed
  end of file.
- On code 2, re-issue the same offset with length `0xFFFFFFFF`. APF clamps it
  to the end of the file, and the word count gives the exact size.

The ring is always ahead of the player, so the real size is known long before
`msu_audio` reaches the end. If phase 0 shows that APF refreshes the slot's
entry in the datatable size table after `0x0192`, the controller can read the
size there instead and skip this.

### Package changes

- `data.json`: two new slots, `"deferload": true`, `"required": false`, no
  filename: id 20 `pcm`, id 21 `msu`. Parameters `0x8` (read-only) if APF
  accepts `0x0192` on a slot that is not user-reloadable; otherwise `0x1`,
  with the side effect that the slots show in the core menu.
- `generate.tcl` / `.qsf`: `USE_MSU '1` for the bitstreams that carry it.
- `core.json`: `version_required` to whichever firmware phase 0 confirms.
- README: folder layout and limitations.

Users would lay out a pack like this and pick the `.sfc` in the Pocket
browser. The browser only lists `smc`/`sfc`/`bs`, so the other files stay
hidden:

```
/Assets/snes/common/MSU-1/Zelda3/zelda3.sfc
/Assets/snes/common/MSU-1/Zelda3/zelda3.msu
/Assets/snes/common/MSU-1/Zelda3/zelda3-1.pcm ... zelda3-34.pcm
```

## Data port (`.msu` file)

Phase 1 enables MSU-1 and serves only audio. Reads from `$2001` return zeros.
Music-only packs, the large majority, never read the data port. Some read
only a few bytes.

Phase 2 serves the data port:

- After detection, preload the whole `.msu` into SDRAM port 1 (banks 2-3, up to
  16 MB) with sequential `0x0180` reads (about 1.4 s per MB). The chunk data
  crosses from the bridge the way the ROM already does, through a
  `data_loader`-style FIFO. The preload finishes before the first track opens,
  so the game never alternates reads between two slots.
- Reuse `msu_data_store.sv` unchanged with `base_addr = 0`. A small adapter
  turns each 64-bit request into four 16-bit port-1 reads. A seek beyond the
  preload watermark holds `data_ack` low (the busy bit stays set) until the
  data is in.
- Port-1 requests must follow the same bus-cycle timing MiSTer uses for WRAM
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

## Unknowns to settle first (phase 0)

Each of these changes the design, and all of them need hardware:

| # | Question | Design impact |
|---|---|---|
| P1 | Does `0x0190` on slot 0 return the full path when the chip32 loader loaded the ROM? | Base of all file naming |
| P2 | Does `0x0192` work on a read-only (`0x8`) deferload slot? Latency in a folder of ~100 files? | Slot parameters; mount latency |
| P3 | After `0x0192`, does the datatable size entry for that slot change? | Size path, or the end-of-file method above |
| P4 | `0x0180` across end of file: code 2 with or without data? Does length `0xFFFFFFFF` clamp as documented? | End-of-file detection |
| P5 | Throughput for 4/8/16/32/64 KB reads; latency of reads scattered over the first 15 MB of a file | Chunk size, watermarks |
| P6 | Cost of alternating reads between slots 20 and 21 | Confirms preload over streaming for `.msu` |
| P7 | How soon after reset exit target commands are accepted | Boot hold length and timeout |
| P8 | Minimum firmware version with `0x0190`/`0x0192` | `core.json` requirement |

The probe build answers P1-P7 in one run (P8 is the firmware version the
tester reports). It shows the results on screen and also writes them to a log
file through an extra nonvolatile data slot, which the Pocket saves on exit
like a save file. `tools/msu_probe.py decode` turns the log into a report.

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

Deliverable: answers P1-P8 from one hardware session.

**Phase 1: audio MVP.** `msu_path`, `msu_apf_ctrl`, `msu_sram`,
`msu_host_shim`, mixer, `USE_MSU '1`, boot hold. Verification before hardware:

- A simulation testbench with a behavioural APF model that serves
  `0x0190`/`0x0192`/`0x0180` from real files on disk, with configurable latency
  and stalls.
- Stubs for the Altera `dcfifo` and the VHDL `CEGen`.
- Scripted MSU-1 register writes. Check the `msu_audio` output bit-exact
  against the `.pcm` samples, across track changes, loops (loop point 0, in the
  middle, past 64 KB), resume, missing tracks, and 200 ms injected stalls.

Hardware: several real packs, long play, and loop points by ear.

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
