# Running the MSU-1 probe (phase 0)

The probe is a debug build of the SNES core. It does not play MSU-1 music. It
measures how your Pocket's firmware opens and reads files while a core runs,
which is what MSU-1 support will be built on. [MSU-1.md](MSU-1.md) explains why
each measurement matters.

It installs as a separate core, `andr3a5n.SNESMSUProbe`, next to the normal
SNES core, and does not change it.

## 1. Build it

The fork's GitHub Actions do the build.

1. Once per fork: open the repository's **Actions** tab and enable workflows
   ("I understand my workflows, go ahead and enable them"). GitHub disables
   them on forks until you do.
2. **Actions** → **MSU-1 Probe** → **Run workflow**, pick the branch, run.
   It simulates the probe first, then compiles, which takes 20 to 40 minutes.
   Pushing a change to the probe's files starts it too.
3. When it is green, download the artifact **SD card - SNES MSU-1 probe** from
   the run's page.

## 2. Install it

Unzip the artifact and copy its three folders (`Assets`, `Cores`,
`Platforms`) to the root of the SD card, merging with what is there. On macOS,
merge rather than replace: Finder replaces folders by default.

That adds:

- `Cores/andr3a5n.SNESMSUProbe/`, the probe core
- `Assets/snes/common/msuprobe/`, a test set: a tiny ROM `msuprobe.sfc` that
  shows a green screen, `msuprobe.msu` (1 MB), `msuprobe-1.pcm` (16 MB) and
  99 small tracks, so the folder looks like a real MSU-1 pack

The test files contain a known pattern, so the probe can check every byte it
reads. They are not playable audio.

If the core does not show up, delete `System/*cache*.bin` on the SD card and
power the Pocket off and on.

## 3. Run it

1. Note your Pocket's firmware version (Settings → System Info).
2. Start the **SNESMSUProbe** core and load
   `Assets/snes/common/msuprobe/msuprobe.sfc`.
3. A dark blue screen shows the ROM's path and a table. `S:` in the top right
   counts the test steps. The run is finished when `S:` reads `4D` and the
   first value (`STA`) starts with `8`. That should take well under a minute.
4. **Take a photo of the screen.**
5. Press **START**. The probe lets the SNES boot, and the screen turns green.
6. Quit the core through the Pocket menu. That makes the Pocket write the probe's
   log file, `msuprobe.msulog`, next to the save files (look under
   `Saves/snes/`).

If `S:` stays at `--`, the firmware never started the core's command handling.
Send the photo anyway; that is a result too.

## 4. Send the results

Send the photo, the `.msulog` file and your firmware version. To read the log
yourself:

```
python3 tools/msu_probe.py decode msuprobe.msulog
```

Optional, and useful: repeat the run with the ROM of a real MSU-1 pack you
own. The probe derives every file name from the loaded ROM, so it then times a
real pack's folder. Pattern mismatches are expected there, because real files
do not contain the test pattern.

## Reading the screen

Each row shows two results as 8 hex digits. For the result codes: `0` is OK,
`3` is "file not found", `2` is "error or out of range", `7` means the firmware
never answered. Times are in cycles of the 74.25 MHz clock (`0x0012_2000` is
about 16 ms).

| Label | Meaning |
|---|---|
| STA | `8000004C` when done; bit 30 set means a command timed out |
| TIM | Run time, in units of 1024 cycles |
| BOT, FST | Boot timing: APF releasing the core, the first command finishing |
| G0E, G0T | Asking for the ROM's path (`0x0190`) |
| GEE, GET | The same for an empty slot |
| OME, OMT | Opening `msuprobe.msu` (`0x0192`) |
| G2E, G2T | Asking for the path of the file just opened |
| O8E, O8T | Opening `msuprobe-1.pcm` into a slot that is not user-reloadable |
| O1E, O1T | The same into a user-reloadable slot |
| MSE, MST | Opening a file that does not exist (expect `3`) |
| OCE, OCT | Opening `msuprobe-100.pcm`, late in the folder |
| ROE, ROT | Opening `msuprobe-1.pcm` again |
| RSL | Slot used for the reads (`80000014` = slot 20) |
| PMM | Bytes that did not match the pattern (expect 0) |
| T4K ... M64 | Reading 512 KB in 4, 8, 16, 32 and 64 KB pieces: total and slowest |
| TPE | Reads that failed or came back short (expect 0) |
| RNT, RNM | Reads scattered over the file: total and slowest |
| ALT, ALM | Reads alternating between the `.pcm` and the `.msu`: total and slowest |
| SZO, SZN, SZT | Finding the end of the file by reading: last good offset, reads, time |
| XRD, CLA, CLB, CLC, FAR | Reads at and past the end of the file: words received and result |
| D20 | The file size the firmware reports for slot 20 |

## Simulation

`sim/msu/run_probe_sim.sh` runs the probe against a model of the firmware
(Icarus Verilog 12 and Python 3 needed). `+dtupdate` and `+clampfail` switch
the model to behaviours the real firmware might have.
