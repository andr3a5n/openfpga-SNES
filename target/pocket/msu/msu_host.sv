// MSU-1 file access on the Pocket: the part the ARM does on MiSTer.
//
// Boot: finds <name>.msu next to the ROM, which turns MSU-1 on, and preloads
// its first DATA_MAX bytes into SRAM for the data port. Without a .msu that
// opens, <name>-1.pcm turns MSU-1 on too (an empty data file): many packs ship
// a 0-byte .msu, and whether the firmware opens those is untested. Then it
// opens <name>-0.pcm, <name>-1.pcm, ... until SCAN_MISSES tracks in a row are
// missing (at most track 255) and keeps each track's size in a table. The SNES
// is held in reset until all this is done, so a game's MSU-1 check at
// power-on sees the result.
//
// Tracks: a request for a track in the table is answered at once, with its
// size or as missing, so the game waits on the audio-busy bit for a few
// microseconds as on MiSTer, instead of the 20-40 ms that opening a file and
// reading its start take on the Pocket. Many MSU-1 patches wait for that bit
// in their NMI handler, where 20-40 ms cost the game one or two frames. The
// file is then opened and read in the background, and sector requests wait
// for it. A track beyond the table is opened first and answered after that.
//
// Streaming: the track goes into a queue of 1 KB sector slots in SRAM. The
// queue holds sectors in playback order: after the file's last sector it
// continues at the loop sector, so when msu_audio reaches the end and seeks
// to the loop point, that sector is already queued. Any other seek flushes
// the queue and refills it from the requested sector.
//
// Sizes come from the datatable: APF writes {slot id, size} for a slot when a
// file is opened into it, at the slot's position in data.json.
//
// Everything here is clk_74a. msu_pocket.sv does the clock crossing to the
// SNES side. The ev* outputs feed the event log (msu_log.sv, codes in
// msu_ev.sv).

module msu_host
  import msu_ev::*;
#(
    parameter [15:0] ROM_SLOT = 16'd0,
    parameter [15:0] AUDIO_SLOT = 16'd20,
    parameter [15:0] DATA_SLOT = 16'd21,
    // Datatable words holding the sizes of the audio and data slots
    // (2 * data.json index + 1)
    parameter [7:0] AUDIO_SIZE_WORD = 8'd5,
    parameter [7:0] DATA_SIZE_WORD = 8'd7,
    // Sector queue: 2^QUEUE_LOG2 slots of 1 KB from SRAM byte 0
    parameter int QUEUE_LOG2 = 6,
    parameter int FETCH_SECTORS = 16,
    // The first read of a track is short, so it starts playing sooner
    parameter int FIRST_FETCH_SECTORS = 4,
    // Track scan at boot: stop after this many missing tracks in a row
    parameter int SCAN_MISSES = 16,
    // Data file store in SRAM
    parameter [17:0] DATA_BASE = 18'h1_0000,
    parameter [31:0] DATA_MAX = 32'h3_0000,
    parameter [31:0] PRELOAD_CHUNK = 32'h1_0000,
    parameter [31:0] TIMEOUT_CYCLES = 32'd222_750_000,  // 3 s
    // Queue reads slower than this are logged (30 ms)
    parameter [31:0] SLOW_READ_CYCLES = 32'd2_227_500,
    parameter int DT_LATENCY = 4
) (
    input wire clk,
    input wire reset_n,  // from core_bridge_cmd: APF has released the core

    // core_bridge_cmd target commands
    output wire        target_dataslot_read,
    output wire        target_dataslot_getfile,
    output wire        target_dataslot_openfile,
    output wire [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output wire [31:0] target_dataslot_bridgeaddr,
    output wire [31:0] target_dataslot_length,
    input  wire        target_dataslot_done,
    input  wire [ 2:0] target_dataslot_err,

    // Datatable port A (the owner mux is in core_top)
    output wire        dt_own,
    output reg  [ 7:0] dt_addr,
    output reg         dt_wren,
    output reg  [31:0] dt_wdata,
    input  wire [31:0] dt_q,

    // SRAM, 16-bit reads
    output reg         sram_rd = 0,
    output reg  [16:0] sram_addr = 0,
    input  wire        sram_done,
    input  wire [15:0] sram_q,

    // Sector words to the SNES side
    output reg        fifo_wr = 0,
    output reg [15:0] fifo_data = 0,

    // Requests from the SNES side
    input wire        track_req,   // pulse
    input wire [15:0] track_num,
    input wire        sector_req,  // pulse
    input wire [21:0] sector_num,

    output reg        track_done = 0,    // pulse
    output reg [31:0] track_size = 0,
    output reg        track_missing = 0,
    output reg        sector_ready = 0,  // pulse, 512 words are in the FIFO

    output reg        enable = 0,       // a .msu file was found
    output reg        booted = 0,       // release the SNES
    output reg [31:0] data_loaded = 0,  // bytes of the data file in SRAM

    // Event log: control and serving, at most one event each per cycle
    output reg        evc_valid = 0,
    output reg [ 7:0] evc_type = 0,
    output reg [23:0] evc_data = 0,
    output reg        evs_valid = 0,
    output reg [ 7:0] evs_type = 0,
    output reg [23:0] evs_data = 0
);
  localparam [1:0] CMD_READ = 2'd0;
  localparam [1:0] CMD_GETFILE = 2'd1;
  localparam [1:0] CMD_OPENFILE = 2'd2;

  localparam int SLOTS = 1 << QUEUE_LOG2;

  // ---------------------------------------------------------------------------
  // Target commands

  reg cmd_start = 0;
  reg [1:0] cmd_kind = 0;
  reg [15:0] cmd_slot = 0;
  reg [31:0] cmd_offset = 0;
  reg [31:0] cmd_addr = 0;
  reg [31:0] cmd_length = 0;

  wire cmd_done;
  wire [2:0] cmd_err;
  wire cmd_timeout;

  msu_tgt_cmd #(
      .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
  ) tgt_cmd (
      .clk  (clk),
      .reset(1'b0),

      .start(cmd_start),
      .cmd(cmd_kind),
      .slot_id(cmd_slot),
      .offset(cmd_offset),
      .bridge_addr(cmd_addr),
      .length(cmd_length),

      .busy(),
      .done(cmd_done),
      .err(cmd_err),
      .timeout(cmd_timeout),
      .cycles(),

      .target_dataslot_read(target_dataslot_read),
      .target_dataslot_getfile(target_dataslot_getfile),
      .target_dataslot_openfile(target_dataslot_openfile),
      .target_dataslot_id(target_dataslot_id),
      .target_dataslot_slotoffset(target_dataslot_slotoffset),
      .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
      .target_dataslot_length(target_dataslot_length),

      .target_dataslot_done(target_dataslot_done),
      .target_dataslot_err (target_dataslot_err)
  );

  // ---------------------------------------------------------------------------
  // Path builder, sharing the datatable port

  reg path_start = 0;
  reg path_pcm = 0;
  reg [15:0] path_track = 0;
  wire path_busy;
  wire path_done;
  wire path_ok;

  wire [7:0] path_dt_addr;
  wire path_dt_wren;
  wire [31:0] path_dt_wdata;

  msu_path #(
      .DT_LATENCY(DT_LATENCY)
  ) path (
      .clk  (clk),
      .reset(1'b0),

      .start(path_start),
      .kind_pcm(path_pcm),
      .track(path_track),

      .busy  (path_busy),
      .done  (path_done),
      .ok    (path_ok),
      .length(),

      .dt_addr (path_dt_addr),
      .dt_wren (path_dt_wren),
      .dt_wdata(path_dt_wdata),
      .dt_q    (dt_q)
  );

  reg own_dt = 0;
  reg [7:0] my_dt_addr = 0;
  assign dt_own = own_dt | path_busy;

  always @(*) begin
    if (path_busy) begin
      dt_addr  = path_dt_addr;
      dt_wren  = path_dt_wren;
      dt_wdata = path_dt_wdata;
    end else begin
      dt_addr  = my_dt_addr;
      dt_wren  = 0;
      dt_wdata = 0;
    end
  end

  // ---------------------------------------------------------------------------
  // Track table: size of each track 0-255 found at boot, 0 if missing.
  // Valid for tracks 0 to scan_last once scan_valid is set.

  reg [31:0] track_table[0:255];
  reg tt_we = 0;
  reg [7:0] tt_waddr = 0;
  reg [31:0] tt_wdata = 0;
  reg [7:0] tt_raddr = 0;
  reg [31:0] tt_q = 0;

  always @(posedge clk) begin
    if (tt_we) track_table[tt_waddr] <= tt_wdata;
    tt_q <= track_table[tt_raddr];
  end

  reg [8:0] scan_track = 0;
  reg [5:0] scan_misses = 0;
  reg [7:0] scan_last = 0;
  reg scan_valid = 0;

  // ---------------------------------------------------------------------------
  // Sector queue

  reg track_loaded = 0;  // reads for the current track may go ahead
  reg track_open = 0;  // mounted: sectors may be served
  reg mount_busy = 0;  // a mount is under way: sector requests wait
  reg [21:0] last_sector = 0;
  reg [21:0] loop_sector = 0;
  reg loop_valid = 0;

  reg [QUEUE_LOG2-1:0] head_slot = 0;
  reg [QUEUE_LOG2-1:0] tail_slot = 0;
  reg [QUEUE_LOG2:0] count = 0;
  reg [21:0] head_sector = 0;  // sector held by head_slot, if count > 0
  reg [21:0] fetch_sector = 0;  // next sector to read into tail_slot
  reg fetch_active = 0;
  reg [7:0] gen = 0;  // bumped by every flush; stale reads are discarded

  wire [QUEUE_LOG2:0] free_slots = SLOTS[QUEUE_LOG2:0] - count;
  wire [QUEUE_LOG2:0] to_ring_end = SLOTS[QUEUE_LOG2:0] - {1'b0, tail_slot};
  wire [21:0] to_eof = last_sector - fetch_sector + 22'd1;

  // Sectors for the next read
  reg [QUEUE_LOG2:0] fetch_n;
  always @(*) begin
    fetch_n = FETCH_SECTORS[QUEUE_LOG2:0];
    if (free_slots < fetch_n) fetch_n = free_slots;
    if (to_ring_end < fetch_n) fetch_n = to_ring_end;
    if (to_eof < {15'b0, fetch_n}) fetch_n = to_eof[QUEUE_LOG2:0];
  end

  wire [QUEUE_LOG2:0] first_n = fetch_n < FIRST_FETCH_SECTORS[QUEUE_LOG2:0] ? fetch_n :
      FIRST_FETCH_SECTORS[QUEUE_LOG2:0];

  // Room for a full read, or for the rest of the file
  wire fetch_wanted = track_loaded && fetch_active && fetch_n != 0 &&
      (free_slots >= FETCH_SECTORS[QUEUE_LOG2:0] || to_eof <= {15'b0, free_slots});

  // Queue updates from both state machines
  reg pop = 0;
  reg [QUEUE_LOG2:0] push_n = 0;
  reg flush = 0;
  reg [21:0] flush_sector = 0;

  // ---------------------------------------------------------------------------
  // Control state machine: boot, mounting, reading

  localparam [5:0] C_WAIT_RESET = 6'd0;
  localparam [5:0] C_GETFILE = 6'd1;
  localparam [5:0] C_PATH_MSU = 6'd2;
  localparam [5:0] C_OPEN_MSU = 6'd3;
  localparam [5:0] C_DATA_SIZE = 6'd4;
  localparam [5:0] C_PRELOAD = 6'd5;
  localparam [5:0] C_BOOTED = 6'd6;
  localparam [5:0] C_IDLE = 6'd7;
  localparam [5:0] C_MOUNT_WAIT = 6'd8;
  localparam [5:0] C_MOUNT_PATH = 6'd9;
  localparam [5:0] C_MOUNT_OPEN = 6'd10;
  localparam [5:0] C_MOUNT_SIZE = 6'd11;
  localparam [5:0] C_MOUNT_FETCH = 6'd12;
  localparam [5:0] C_MOUNT_LOOP_LO = 6'd13;
  localparam [5:0] C_MOUNT_LOOP_HI = 6'd14;
  localparam [5:0] C_MOUNT_READY = 6'd15;
  localparam [5:0] C_FETCH = 6'd16;
  localparam [5:0] C_WAIT_CMD = 6'd17;
  localparam [5:0] C_WAIT_PATH = 6'd18;
  localparam [5:0] C_READ_DT = 6'd19;
  localparam [5:0] C_PATH_PCM1 = 6'd20;
  localparam [5:0] C_OPEN_PCM1 = 6'd21;
  localparam [5:0] C_SCAN_PATH = 6'd22;
  localparam [5:0] C_SCAN_OPEN = 6'd23;
  localparam [5:0] C_SCAN_RESULT = 6'd24;
  localparam [5:0] C_SCAN_SIZE = 6'd25;
  localparam [5:0] C_SCAN_NEXT = 6'd26;
  localparam [5:0] C_MOUNT_LOOKUP = 6'd27;
  localparam [5:0] C_MOUNT_LOOKUP2 = 6'd28;
  localparam [5:0] C_MOUNT_FAIL = 6'd29;

  reg [5:0] cstate = C_WAIT_RESET;
  reg [5:0] cret = C_WAIT_RESET;
  reg [3:0] wait_cnt = 0;

  reg [2:0] res_err = 0;
  reg res_timeout = 0;
  reg [31:0] dt_value = 0;

  reg track_pending = 0;
  reg [15:0] pending_track = 0;
  reg [15:0] cur_track = 0;
  reg reported = 0;  // the current mount has answered the SNES

  reg [31:0] preload_len = 0;
  reg [31:0] preload_offset = 0;
  reg [31:0] preload_last = 0;

  reg [QUEUE_LOG2:0] inflight_n = 0;
  reg [7:0] inflight_gen = 0;
  reg inflight_logged = 0;  // a command whose start and end go to the log
  reg [31:0] cmd_cycles = 0;
  reg [15:0] loop_lo = 0;

  // Serve state machine
  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_READ = 2'd1;
  localparam [1:0] S_WAIT = 2'd2;
  localparam [1:0] S_ZERO = 2'd3;

  reg [1:0] sstate = S_IDLE;
  reg sector_pending = 0;
  reg [21:0] pending_sector = 0;
  reg [8:0] word_idx = 0;
  reg flush_requested = 0;
  reg sector_waited = 0;  // this request was logged as waiting

  wire [31:0] sector_offset = {fetch_sector, 10'b0};
  wire [31:0] file_left = track_size - sector_offset;

  task evc(input [7:0] t, input [23:0] d);
    begin
      evc_valid <= 1;
      evc_type  <= t;
      evc_data  <= d;
    end
  endtask

  task evs(input [7:0] t, input [23:0] d);
    begin
      evs_valid <= 1;
      evs_type  <= t;
      evs_data  <= d;
    end
  endtask

  // logged: the command's start and end go to the event log. Routine queue
  // reads are logged only when slow.
  task start_cmd(input [1:0] kind, input [15:0] slot, input [31:0] offset, input [31:0] addr,
                 input [31:0] length, input [5:0] ret, input logged);
    begin
      cmd_kind <= kind;
      cmd_slot <= slot;
      cmd_offset <= offset;
      cmd_addr <= addr;
      cmd_length <= length;
      cmd_start <= 1;
      cret <= ret;
      cstate <= C_WAIT_CMD;
      inflight_logged <= logged;
      cmd_cycles <= 0;
      if (logged) evc(EV_CMD, kind == CMD_READ ? {kind, offset[31:10]} : {kind, 6'b0, slot});
    end
  endtask

  task read_dt(input [7:0] word, input [5:0] ret);
    begin
      own_dt <= 1;
      my_dt_addr <= word;
      wait_cnt <= 0;
      cret <= ret;
      cstate <= C_READ_DT;
    end
  endtask

  task open_track(input [15:0] track, input [5:0] ret);
    begin
      path_pcm <= 1;
      path_track <= track;
      path_start <= 1;
      cret <= ret;
      cstate <= C_WAIT_PATH;
    end
  endtask

  // Answer the SNES: size, or missing
  task report(input missing, input [31:0] size, input fast);
    begin
      track_missing <= missing;
      track_size <= missing ? 32'd0 : size;
      track_done <= 1;
      reported <= 1;
      evc(EV_TRACK_REPORT, {fast, missing, 6'b0, cur_track});
    end
  endtask

  always @(posedge clk) begin
    cmd_start <= 0;
    path_start <= 0;
    sram_rd <= 0;
    fifo_wr <= 0;
    track_done <= 0;
    sector_ready <= 0;
    pop <= 0;
    push_n <= 0;
    flush <= 0;
    tt_we <= 0;
    evc_valid <= 0;
    evs_valid <= 0;

    if (track_req) begin
      track_pending <= 1;
      pending_track <= track_num;
    end
    if (sector_req) begin
      sector_pending <= 1;
      pending_sector <= sector_num;
      sector_waited <= 0;
    end

    // ---- Queue bookkeeping (the flags were set by the previous cycle) ----
    if (flush) begin
      gen <= gen + 1;
      count <= 0;
      head_slot <= 0;
      tail_slot <= 0;
      head_sector <= flush_sector;
      fetch_sector <= flush_sector;
      fetch_active <= 1;
    end else begin
      count <= count + push_n - pop;
      if (pop) begin
        head_slot <= head_slot + 1;
        head_sector <= (head_sector == last_sector && loop_valid) ? loop_sector :
            head_sector + 22'd1;
      end
      if (push_n != 0) begin
        tail_slot <= tail_slot + push_n[QUEUE_LOG2-1:0];
        if (fetch_sector + push_n > last_sector) begin
          // Past the end: continue at the loop point, or stop
          fetch_sector <= loop_sector;
          fetch_active <= loop_valid;
        end else begin
          fetch_sector <= fetch_sector + push_n;
        end
      end
    end

    // ---- Control ----
    case (cstate)
      C_WAIT_RESET: begin
        // Explicit clears keep these real registers in Quartus
        booted <= 0;
        enable <= 0;
        data_loaded <= 0;
        track_pending <= 0;
        track_open <= 0;
        track_loaded <= 0;
        mount_busy <= 0;
        fetch_active <= 0;
        loop_valid <= 0;
        res_timeout <= 0;
        flush_requested <= 0;
        scan_valid <= 0;
        if (reset_n) begin
          start_cmd(CMD_GETFILE, ROM_SLOT, 0, 0, 0, C_GETFILE, 1);
        end
      end

      C_GETFILE: begin
        if (res_err != 0) begin
          evc(EV_BOOT_MSU, 0);
          cstate <= C_BOOTED;
        end else begin
          path_pcm <= 0;
          path_start <= 1;
          cret <= C_PATH_MSU;
          cstate <= C_WAIT_PATH;
        end
      end

      C_PATH_MSU: begin
        if (~path_ok) begin
          evc(EV_BOOT_MSU, 0);
          cstate <= C_BOOTED;
        end else begin
          start_cmd(CMD_OPENFILE, DATA_SLOT, 0, 0, 0, C_OPEN_MSU, 1);
        end
      end

      C_OPEN_MSU: begin
        if (res_err != 0) begin
          // No <name>.msu that opens: look for track 1
          open_track(16'd1, C_PATH_PCM1);
        end else begin
          read_dt(DATA_SIZE_WORD, C_DATA_SIZE);
        end
      end

      C_PATH_PCM1: begin
        if (~path_ok) begin
          evc(EV_BOOT_MSU, 0);
          cstate <= C_BOOTED;
        end else begin
          start_cmd(CMD_OPENFILE, AUDIO_SLOT, 0, 0, 0, C_OPEN_PCM1, 1);
        end
      end

      C_OPEN_PCM1: begin
        // Neither file: not an MSU-1 game
        if (res_err == 0) begin
          enable <= 1;
          evc(EV_BOOT_MSU, 2);
          scan_track <= 0;
          scan_misses <= 0;
          cstate <= C_SCAN_PATH;
        end else begin
          evc(EV_BOOT_MSU, 0);
          cstate <= C_BOOTED;
        end
      end

      C_DATA_SIZE: begin
        enable <= 1;
        evc(EV_BOOT_MSU, 1);
        preload_len <= dt_value > DATA_MAX ? DATA_MAX : dt_value;
        preload_offset <= 0;
        cstate <= C_PRELOAD;
      end

      C_PRELOAD: begin
        if (res_err != 0 || preload_offset >= preload_len) begin
          // Done, or the last read failed: keep what arrived before it
          data_loaded <= res_err != 0 ? preload_offset - preload_last : preload_offset;
          evc(EV_BOOT_DATA, res_err != 0 ? preload_offset - preload_last : preload_offset);
          scan_track <= 0;
          scan_misses <= 0;
          cstate <= C_SCAN_PATH;
        end else begin
          preload_last <= preload_len - preload_offset > PRELOAD_CHUNK ? PRELOAD_CHUNK :
              preload_len - preload_offset;
          preload_offset <= preload_offset +
              (preload_len - preload_offset > PRELOAD_CHUNK ? PRELOAD_CHUNK :
                                                              preload_len - preload_offset);
          start_cmd(CMD_READ, DATA_SLOT, preload_offset,
                    32'h3000_0000 + {14'b0, DATA_BASE} + preload_offset,
                    preload_len - preload_offset > PRELOAD_CHUNK ? PRELOAD_CHUNK :
                                                                   preload_len - preload_offset,
                    C_PRELOAD, 1);
        end
      end

      // ---- Track scan ----
      C_SCAN_PATH: begin
        if (res_timeout) begin
          cstate <= C_BOOTED;
        end else begin
          open_track({7'b0, scan_track}, C_SCAN_OPEN);
        end
      end

      C_SCAN_OPEN: begin
        if (~path_ok) begin
          cstate <= C_BOOTED;
        end else begin
          start_cmd(CMD_OPENFILE, AUDIO_SLOT, 0, 0, 0, C_SCAN_RESULT, 0);
        end
      end

      C_SCAN_RESULT: begin
        if (res_err != 0) begin
          tt_we <= 1;
          tt_waddr <= scan_track[7:0];
          tt_wdata <= 0;
          if (scan_track != 0) scan_misses <= scan_misses + 1'd1;
          evc(EV_SCAN, {scan_track[7:0], 16'd0});
          cstate <= C_SCAN_NEXT;
        end else begin
          read_dt(AUDIO_SIZE_WORD, C_SCAN_SIZE);
        end
      end

      C_SCAN_SIZE: begin
        tt_we <= 1;
        tt_waddr <= scan_track[7:0];
        tt_wdata <= dt_value < 32'd8 ? 32'd0 : dt_value;
        if (dt_value < 32'd8) begin
          if (scan_track != 0) scan_misses <= scan_misses + 1'd1;
        end else begin
          scan_misses <= 0;
        end
        evc(EV_SCAN, {
            scan_track[7:0],
            dt_value < 32'd8 ? 16'd0 : (dt_value[31:26] != 0 ? 16'hFFFF : dt_value[25:10])
        });
        cstate <= C_SCAN_NEXT;
      end

      C_SCAN_NEXT: begin
        scan_last <= scan_track[7:0];
        scan_valid <= 1;
        if (scan_track == 9'd255 || scan_misses >= SCAN_MISSES[5:0]) begin
          evc(EV_BOOT_DONE, {16'd0, scan_track[7:0]});
          cstate <= C_BOOTED;
        end else begin
          scan_track <= scan_track + 1'd1;
          cstate <= C_SCAN_PATH;
        end
      end

      C_BOOTED: begin
        booted <= 1;
        cstate <= C_IDLE;
      end

      C_IDLE: begin
        if (track_pending) begin
          track_pending <= 0;
          cur_track <= pending_track;
          reported <= 0;
          track_open <= 0;
          track_loaded <= 0;
          mount_busy <= 1;
          // Requests and flushes for the old track are void
          sector_pending <= 0;
          flush_requested <= 0;
          evc(EV_TRACK_REQ, {8'd0, pending_track});
          cstate <= C_MOUNT_WAIT;
        end else if (res_timeout) begin
          // Nothing can be issued any more
        end else if (flush_requested) begin
          flush_requested <= 0;
          flush <= 1;
          flush_sector <= pending_sector;
          evc(EV_FLUSH, {2'b0, pending_sector});
        end else if (fetch_wanted && ~flush && push_n == 0) begin
          // (push_n: the last read's sectors reach count and fetch_sector
          // only in the next cycle)
          inflight_n <= fetch_n;
          inflight_gen <= gen;
          start_cmd(CMD_READ, AUDIO_SLOT, sector_offset,
                    32'h3000_0000 + {{(22 - QUEUE_LOG2) {1'b0}}, tail_slot, 10'b0},
                    fetch_sector + fetch_n - 1 == last_sector ? file_left : {fetch_n, 10'b0},
                    C_FETCH, 0);
        end
      end

      C_FETCH: begin
        if (res_err == 0 && inflight_gen == gen && ~flush) push_n <= inflight_n;
        else if (res_err != 0) fetch_active <= 0;
        if (cmd_cycles > SLOW_READ_CYCLES) evc(EV_READ_SLOW, cmd_cycles[29:6]);
        cstate <= C_IDLE;
      end

      // ---- Mounting a track ----
      C_MOUNT_WAIT: begin
        // Let a sector being served finish before the queue is reset
        if (sstate == S_IDLE) begin
          if (res_timeout) begin
            // APF stopped answering, so nothing more can be read. Report the
            // track missing: the game falls back to its own music.
            report(1, 0, 0);
            cstate <= C_MOUNT_FAIL;
          end else if (scan_valid && cur_track <= {8'd0, scan_last}) begin
            tt_raddr <= cur_track[7:0];
            cstate <= C_MOUNT_LOOKUP;
          end else begin
            open_track(cur_track, C_MOUNT_PATH);
          end
        end
      end

      C_MOUNT_LOOKUP: cstate <= C_MOUNT_LOOKUP2;  // table read latency

      C_MOUNT_LOOKUP2: begin
        if (tt_q == 0) begin
          report(1, 0, 1);
          cstate <= C_MOUNT_FAIL;
        end else begin
          report(0, tt_q, 1);
          open_track(cur_track, C_MOUNT_PATH);
        end
      end

      C_MOUNT_PATH: begin
        if (~path_ok) begin
          res_err <= 3'd4;
          cstate <= C_MOUNT_FAIL;
        end else begin
          start_cmd(CMD_OPENFILE, AUDIO_SLOT, 0, 0, 0, C_MOUNT_OPEN, 1);
        end
      end

      C_MOUNT_OPEN: begin
        if (reported && track_pending) begin
          // The game has moved on to another track
          evc(EV_MOUNT_ABANDON, {8'd0, cur_track});
          mount_busy <= 0;
          cstate <= C_IDLE;
        end else if (res_err != 0) begin
          cstate <= C_MOUNT_FAIL;
        end else begin
          read_dt(AUDIO_SIZE_WORD, C_MOUNT_SIZE);
        end
      end

      C_MOUNT_SIZE: begin
        if (dt_value < 32'd8) begin
          // Not even the 8-byte header
          res_err <= 3'd4;
          cstate <= C_MOUNT_FAIL;
        end else begin
          if (~reported) report(0, dt_value, 0);
          else track_size <= dt_value;
          last_sector <= (dt_value - 1) >> 10;
          loop_valid <= 0;
          flush <= 1;
          flush_sector <= 0;
          track_loaded <= 1;
          cstate <= C_MOUNT_FETCH;
        end
      end

      C_MOUNT_FETCH: begin
        // Read the start of the file once the flush has been applied
        if (flush) begin
          // Next cycle
        end else if (fetch_wanted) begin
          inflight_n <= first_n;
          inflight_gen <= gen;
          start_cmd(CMD_READ, AUDIO_SLOT, 0, 32'h3000_0000,
                    first_n - 1 == last_sector ? track_size : {first_n, 10'b0},
                    C_MOUNT_LOOP_LO, 1);
        end else begin
          cstate <= C_MOUNT_READY;
        end
      end

      // Bytes 4-7 of the file: the loop point in samples
      C_MOUNT_LOOP_LO: begin
        if (res_err != 0) begin
          cstate <= C_MOUNT_FAIL;
        end else begin
          push_n <= inflight_n;
          sram_addr <= 17'd2;
          sram_rd <= 1;
          cstate <= C_MOUNT_LOOP_HI;
        end
      end

      C_MOUNT_LOOP_HI: begin
        if (sram_done) begin
          if (sram_addr == 17'd2) begin
            loop_lo <= sram_q;
            sram_addr <= 17'd3;
            sram_rd <= 1;
          end else begin
            // loop_index in msu_audio is the sample plus the 2-dword header
            if ((({sram_q, loop_lo} + 32'd2) >> 8) <= {10'b0, last_sector}) begin
              loop_sector <= ({sram_q, loop_lo} + 32'd2) >> 8;
              loop_valid <= 1;
              // A short file may already be completely queued
              if (~fetch_active) begin
                fetch_sector <= ({sram_q, loop_lo} + 32'd2) >> 8;
                fetch_active <= 1;
              end
            end
            cstate <= C_MOUNT_READY;
          end
        end
      end

      C_MOUNT_READY: begin
        track_open <= 1;
        mount_busy <= 0;
        evc(EV_MOUNT_READY, {loop_valid, 1'b0, loop_sector});
        cstate <= C_IDLE;
      end

      C_MOUNT_FAIL: begin
        // Missing, or failed after the SNES was told the track exists: then
        // its sectors are served as silence
        if (~reported) report(1, 0, 0);
        else if (~track_missing) evc(EV_MOUNT_FAIL, {21'd0, res_err});
        track_loaded <= 0;
        mount_busy <= 0;
        cstate <= C_IDLE;
      end

      // ---- Subroutines ----
      C_WAIT_CMD: begin
        cmd_cycles <= cmd_cycles + 1;
        if (cmd_done) begin
          res_err <= cmd_err;
          if (cmd_timeout) res_timeout <= 1;
          if (inflight_logged) evc(EV_CMD_DONE, {cmd_timeout, cmd_err, 20'd0});
          cstate <= cret;
        end
      end

      C_WAIT_PATH: begin
        if (path_done) cstate <= cret;
      end

      C_READ_DT: begin
        wait_cnt <= wait_cnt + 1;
        if (wait_cnt == DT_LATENCY[3:0]) begin
          dt_value <= dt_q;
          own_dt <= 0;
          cstate <= cret;
        end
      end

      default: cstate <= C_WAIT_RESET;
    endcase

    // APF puts the core back into reset to load another game: start over
    // once a command in flight has finished
    if (~reset_n && cstate != C_WAIT_CMD) cstate <= C_WAIT_RESET;

    // ---- Serving sectors ----
    case (sstate)
      S_IDLE: begin
        word_idx <= 0;
        if (sector_pending && ~flush && ~flush_requested && ~mount_busy) begin
          if (~track_open || res_timeout || pending_sector > last_sector) begin
            // Nothing to play: silence rather than a stuck msu_audio
            evs(EV_SECTOR_ZERO, {2'b0, pending_sector});
            sstate <= S_ZERO;
          end else if (pop || push_n != 0) begin
            // The queue changes this cycle: decide in the next
          end else if (count != 0 && head_sector == pending_sector) begin
            sstate <= S_READ;
          end else begin
            if (count == 0 && fetch_active && fetch_sector == pending_sector) begin
              // On its way
            end else begin
              flush_requested <= 1;
            end
            if (~sector_waited) begin
              sector_waited <= 1;
              evs(EV_SECTOR_WAIT, {2'b0, pending_sector});
            end
          end
        end else if (sector_pending && mount_busy && ~sector_waited) begin
          sector_waited <= 1;
          evs(EV_SECTOR_WAIT, {2'b0, pending_sector});
        end
      end

      S_READ: begin
        sram_addr <= {head_slot, word_idx};
        sram_rd <= 1;
        sstate <= S_WAIT;
      end

      S_WAIT: begin
        if (sram_done) begin
          fifo_wr <= 1;
          fifo_data <= sram_q;
          word_idx <= word_idx + 1;
          if (word_idx == 9'd511) begin
            pop <= 1;
            sector_pending <= 0;
            sector_ready <= 1;
            if (sector_waited) evs(EV_SECTOR_READY, {2'b0, pending_sector});
            sstate <= S_IDLE;
          end else begin
            sstate <= S_READ;
          end
        end
      end

      S_ZERO: begin
        fifo_wr <= 1;
        fifo_data <= 0;
        word_idx <= word_idx + 1;
        if (word_idx == 9'd511) begin
          sector_pending <= 0;
          sector_ready <= 1;
          sstate <= S_IDLE;
        end
      end
    endcase
  end
endmodule
