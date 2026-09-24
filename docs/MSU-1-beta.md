# MSU-1 beta core

`andr3a5n.SNESMSU` is the SNES core with MSU-1 support: CD-quality music
tracks (`.pcm`) and the data file (`.msu`) of MSU-1 packs. It installs as a
separate core next to the normal SNES core and does not change it. How it
works is in [MSU-1.md](MSU-1.md).

Status: beta 2. The first build played the test ROM correctly on a Pocket
(firmware 2.7), and Super Mario Kart and Super Metroid packs played music.
It showed four problems, which beta 2 addresses:

| Seen with beta 1 | Cause | Beta 2 |
|---|---|---|
| Click when a track stops or starts | The output was cut at full volume | 1.5 ms fade out and in, smoothed volume steps |
| Super Mario Kart: one or two green or white frames at each music change | Probably the game waiting 20-40 ms on the audio-busy bit while the Pocket opened the track | Tracks answered from a table built at boot: busy lasts about 10 us |
| Super Metroid: black screen when some tracks start | Probably the same wait | As above |
| - | No way to see what happens on the Pocket | Event log saved to the SD card, see [Reporting a problem](#5-reporting-a-problem) |

The two "probably" rows are the leading explanation, not yet confirmed; the
event log of beta 2 will show whether they are fixed.

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
  data file and three tracks

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
| cyan | track 3, the measurement signal, is playing; grey again when it has finished |
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
| R | play track 3 once: the measurement signal (19 s, see below) |
| X | pause track 1; press again to resume where it was |
| Y | stop |
| Up / Down | MSU-1 volume up / down |

Things worth reporting: clicks, gaps or stutter, left and right swapped, the
arpeggio not repeating or repeating from the wrong place, and how long the
screen stays grey at the start.

Track 3 is for recordings, not for listening: 1 s silence, 1 kHz on both
channels (2 s), on the left (1 s), on the right (1 s), 0.5 s silence, a sweep
from 20 Hz to 20 kHz (10 s), 0.5 s silence, single-sample clicks every 100 ms
(2 s), 1 s silence. The tones and the sweep are at -6 dBFS. Every sample is
known, so a recording of it measures level, channel balance, frequency
response, distortion and timing exactly.

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
out at power-on, which adds a short delay before the game starts. For an
MSU-1 game it also opens every track once, to answer the game's track
changes at once later: about 15 ms per track, so a pack of 40 tracks starts
about a second later.

## 5. Reporting a problem

The core records what MSU-1 does, and the Pocket saves it when you quit the
core: a file `<ROM name>.msulog` next to the save files (under `Saves/snes/`).
It holds the last 2000 or so events with a time in microseconds: every track
the game selects, how long the audio-busy bit stayed set, when each file was
opened and read, sector requests that had to wait, data port seeks, and every
8 frames the address the SNES reads its ROM at, which shows where a game
hangs. `tools/msu_log.py <file>` prints it.

For each problem:

1. Start the game fresh, play to the problem, and **quit the core from the
   Pocket menu soon after it happens** (the log keeps only the recent past).
2. Send the `.msulog` file and a sentence on what you saw and when.
3. Helpful, if you can: a recording of the Pocket's output through the dock
   and a capture card, as lossless audio (WAV or FLAC, 48 kHz), and the same
   passage from an emulator with good MSU-1 support (ares, bsnes, Mesen or
   Snes9x) at the same volume. A short video clip shows visual glitches frame
   by frame.
4. The MSU-1 patch file of the game (`.bps` or `.ips`), or where you got it.
   The patch contains the hack's own code, which shows how it drives the
   MSU-1 registers. Please do not send ROMs.
5. Say whether you listened through headphones or the speaker, or through
   the dock.

A recording of track 3 of the test ROM (press R) through the dock is the most
useful single recording for sound quality.

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
- **Track changes** for tracks the boot scan found (it stops after 16
  missing track numbers in a row, and at 255) are answered in about 10 us;
  the track's music then starts 15-35 ms later, once the file is open and
  its start read. Tracks beyond the scan are opened before the game gets its
  answer (20-30 ms).
- **Fades.** Stopping or changing a track fades the old one out over 1.5 ms,
  starting one fades in over 1.5 ms, and volume writes move in steps of 6 us.
  A track that ends by itself still stops at once, as upstream.
- **Sound quality.** MSU-1 audio (44.1 kHz) reaches the Pocket's 48 kHz
  output by holding the latest sample, as the SNES audio does in this core.
  That adds aliasing: modelled, a 1 kHz tone gets a false tone at 4.9 kHz at
  -33 dB, a 5 kHz tone one at 8.9 kHz at -18 dB. A proper resampler is the
  next step for sound quality, once a recording of track 3 confirms this on
  the hardware.
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
  Every sample is compared with the source file. It fails if msu_audio's
  output is ever cut at a volume above zero (a click), or if the audio-busy
  bit stays set longer than 2.5 ms for a track in the boot table, and it
  plays a track beyond the table. At the end it reads the event log over the
  bridge as APF does and decodes it. A second run checks that MSU-1 comes on
  without a `.msu` file. Needs Icarus Verilog 12 and Python 3.
- `sim/msu/check_testrom.py`: runs the test ROM in a 65816 interpreter against
  a model of the MSU-1 registers and checks every colour and register write
  for scripted button presses.
