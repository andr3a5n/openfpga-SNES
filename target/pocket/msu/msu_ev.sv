// Event codes for the MSU-1 event log (msu_log.sv). tools/msu_log.py decodes
// them; keep the two in step. Each event has 24 bits of data.

package msu_ev;
  // Boot (msu_host)
  localparam [7:0] EV_BOOT_START = 8'h10;  // 0
  localparam [7:0] EV_BOOT_MSU = 8'h11;  // 0 no MSU-1, 1 .msu found, 2 only <name>-1.pcm
  localparam [7:0] EV_BOOT_DATA = 8'h12;  // bytes of the data file preloaded
  localparam [7:0] EV_SCAN = 8'h13;  // {track[7:0], size in KB[15:0]}, size 0: missing
  localparam [7:0] EV_BOOT_DONE = 8'h14;  // highest track in the table

  // Tracks (msu_host)
  localparam [7:0] EV_TRACK_REQ = 8'h20;  // track
  localparam [7:0] EV_TRACK_REPORT = 8'h21;  // {fast, missing, 6'b0, track[15:0]}
  localparam [7:0] EV_MOUNT_READY = 8'h22;  // {loop valid, 1'b0, loop sector[21:0]}
  localparam [7:0] EV_MOUNT_FAIL = 8'h23;  // result code
  localparam [7:0] EV_MOUNT_ABANDON = 8'h24;  // a newer request replaced this mount

  // Target commands (msu_host)
  localparam [7:0] EV_CMD = 8'h30;  // {kind[1:0], read: offset in KB[21:0] / else: slot}
  localparam [7:0] EV_CMD_DONE = 8'h31;  // {timeout, result[2:0], 20'b0}
  localparam [7:0] EV_FLUSH = 8'h32;  // sector
  localparam [7:0] EV_READ_SLOW = 8'h33;  // a queue read that took longer than 30 ms: us

  // Serving sectors (msu_host)
  localparam [7:0] EV_SECTOR_WAIT = 8'h40;  // sector, not served at once
  localparam [7:0] EV_SECTOR_READY = 8'h41;  // sector, after EV_SECTOR_WAIT
  localparam [7:0] EV_SECTOR_ZERO = 8'h42;  // sector, served as silence

  // SNES side (msu_pocket, clk_sys)
  localparam [7:0] EV_S_TRACK = 8'h80;  // the game selected a track: number
  localparam [7:0] EV_S_BUSY_END = 8'h81;  // audio-busy bit cleared
  localparam [7:0] EV_S_CTRL = 8'h82;  // {resume, repeat, playing}
  localparam [7:0] EV_S_VOLUME = 8'h83;  // volume (at most one event per 4 frames)
  localparam [7:0] EV_S_END = 8'h84;  // a track without repeat reached its end
  localparam [7:0] EV_S_DSEEK = 8'h85;  // data port seek: address[23:0]
  localparam [7:0] EV_S_DREADY = 8'h86;  // data port seek done
  localparam [7:0] EV_S_ROM = 8'h87;  // ROM address sample, every 8 frames
  localparam [7:0] EV_S_RESET = 8'h88;  // 1: SNES reset asserted, 0: released

  // Log
  localparam [7:0] EV_LOG_LOST = 8'hF0;  // events dropped because the input was full
endpackage
