# MSU-1 beta core

`andr3a5n.SNESMSU` is the SNES core with MSU-1 support: CD-quality music
tracks (`.pcm`) and the data file (`.msu`) of MSU-1 packs. It installs as a
separate core next to the normal SNES core and does not change it. How it
works is in [MSU-1.md](MSU-1.md).

This is a first hardware build. It passed simulation, but has not run on a
Pocket yet.

## 1. Build it

The fork's GitHub Actions do the build.

1. **Actions** → **MSU-1 Beta** → **Run workflow**, pick the branch, run.
   It runs the simulations, then compiles five bitstreams in parallel (about
   40 minutes), then packages them.
2. When it is green, download the artifact **SD card - SNES MSU-1 beta** from
   the run's page.

Pushes to the MSU-1 files run only the simulations, which take a few
minutes. Building the bitstreams is always a manual run.

## 2. Install it

Unzip the artifact and copy its three folders (`Assets`, `Cores`,
`Platforms`) to the root of the SD card, merging with what is there. That
adds:

- `Cores/andr3a5n.SNESMSU/`, the core
- `Assets/snes/common/msu1test/`, a small MSU-1 test: `msu1test.sfc`, its
  data file and two tracks

If the core does not show up, delete `System/*cache*.bin` on the SD card and
power the Pocket off and on.

## 3. Check it with the test ROM

Start the **SNESMSU** core and load `Assets/snes/common/msu1test/msu1test.sfc`.
The test ROM draws no graphics. The whole screen changes colour:

| Colour | Meaning |
|---|---|
| grey | starting (under a second), or stopped |
| red | no MSU-1: the core did not find `msu1test.msu`, or this is not the SNESMSU core |
| magenta | MSU-1 is on, but the data port returned wrong bytes |
| yellow | the selected track is missing |
| green | track 1 is playing |
| blue | track 2 is playing; grey again when it has finished |
| white | track 1 is paused, ready to resume |

What you should hear on green: a tone on the **left** only, the same tone on
the **right** only, then a four-note rising arpeggio that repeats without a
gap. The repeat starts at the arpeggio, not at the tones: that checks the loop
point.

Buttons:

| Button | Action |
|---|---|
| A | play track 1 from the start (it loops) |
| B | play track 2 once: three falling notes |
| X | pause track 1; press again to resume where it was |
| Y | stop |
| Up / Down | MSU-1 volume up / down |

Things worth reporting: clicks, gaps or stutter, left and right swapped, the
arpeggio not repeating or repeating from the wrong place, and how long the
screen stays grey at the start.

## 4. Play an MSU-1 pack

MSU-1 packs come as a patch for the game's ROM plus the audio files. Patch the
ROM as the pack says (usually a `.bps` or `.ips` patch for a specific ROM
version), then put the patched ROM and the pack's files into one folder under
`Assets/snes/common/`, all named like the ROM:

```
Assets/snes/common/Zelda MSU/
  Zelda MSU.sfc      patched ROM
  Zelda MSU.msu      data file, often empty (0 bytes)
  Zelda MSU-1.pcm    track 1
  Zelda MSU-2.pcm    track 2
  ...
```

Rename the files if the pack names them differently: the core looks for
`<ROM name>.msu` and `<ROM name>-<track>.pcm` in the ROM's folder. The whole
path must stay under 255 characters.

Games without these files run as they do in the normal core. The core finds
out at power-on: that adds a short delay before the game starts, well under a
second.

## What works and what does not

- **Chips.** MSU-1 works in games without a coprocessor and with DSP-1 to
  DSP-4, CX4, SA-1 and Super FX, which covers the popular packs (for example
  Zelda: A Link to the Past, Super Metroid, Chrono Trigger, Mega Man X to X3,
  Super Mario Kart, Super Mario RPG, Star Fox). S-DD1, SPC7110, BS-X and all
  PAL ROMs run in the normal bitstreams, without MSU-1.
- **Data file.** The first 192 KB of the `.msu` file are served. Most audio
  packs use an empty `.msu` or a small one. Hacks that stream video or large
  graphics through the data port (MSU-1 FMV games) do not work: the data port
  returns zeros beyond 192 KB.
- **Track ends.** A track that plays once stops up to 17 ms before its end.
  If the game plays it again without selecting it anew, those samples play
  first. MiSTer does the same; it is how the upstream MSU-1 player works.
- **Resume** (bit 2 of `$2007`) continues at a 1 KB sector boundary up to
  about 25 ms past where the track paused, as on MiSTer.
- **Settings.** No MSU-1 options in the menu yet. The game sets the MSU-1
  volume; the core mixes MSU-1 audio with the SNES audio at full scale.

## Build types and loader

| Core id | Bitstream | `generate.tcl` | Chips | MSU-1 |
|---|---|---|---|---|
| 0 | `snes_msu.rev` | `msu` | DSP-n, CX4, none | yes |
| 1 | `snes_spc.rev` | `ntsc_spc` | S-DD1, SPC7110, BS-X | no |
| 2 | `snes_pal.rev` | `pal` | all four, PAL | no |
| 3 | `snes_msu_sa1.rev` | `msu_sa1` | SA-1 | yes |
| 4 | `snes_msu_gsu.rev` | `msu_gsu` | Super FX | yes |

The chip32 loader (`support/loader.asm` assembled with `-d MSU=1`) picks the
bitstream from the ROM header. `tools/package_msu.py` builds the SD card tree
from the five `.rbf` files.

## Simulation

- `sim/msu/run_play_sim.sh`: the MSU-1 path end to end. The unchanged
  upstream `MSU.sv`, `msu_audio.v` and `msu_data_store.sv` are served by
  `target/pocket/msu/msu_pocket.sv` against `core_bridge_cmd.v`, a model of
  the Pocket firmware and an SRAM model. A scripted CPU identifies the MSU-1,
  reads the data port, plays a looping track through a 50 ms firmware stall,
  changes track while playing, plays a track once, replays it and resumes.
  Every sample is compared with the source file. A second run checks that
  MSU-1 comes on without a `.msu` file. Needs Icarus Verilog 12 and Python 3.
- `sim/msu/check_testrom.py`: runs the test ROM in a 65816 interpreter against
  a model of the MSU-1 registers and checks every colour and register write
  for scripted button presses.
