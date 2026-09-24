// MSU-1 file access on the Pocket: the part the ARM does on MiSTer.
//
// Boot: finds <name>.msu next to the ROM, which turns MSU-1 on, and preloads
// its first DATA_MAX bytes into SRAM for the data port. Without a .msu that
// opens, <name>-1.pcm turns MSU-1 on too (an empty data file): many packs ship
// a 0-byte .msu, and whether the firmware opens those is untested. The SNES is held in
// reset until this is done, so a game's MSU-1 check at power-on sees it.
//
// Tracks: opens <name>-<n>.pcm on request and streams it into a queue of
// 1 KB sector slots in SRAM. The queue holds sectors in playback order: after
// the file's last sector it continues at the loop sector, so when msu_audio
// reaches the end and seeks to the loop point, that sector is already queued.
// Any other seek flushes the queue and refills it from the requested sector.
//
// Sizes come from the datatable: APF writes {slot id, size} for a slot when a
// file is opened into it, at the slot's position in data.json.
//
// Everything here is clk_74a. msu_pocket.sv does the clock crossing to the
// SNES side.

module msu_host #(
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
    // Data file store in SRAM
    parameter [17:0] DATA_BASE = 18'h1_0000,
    parameter [31:0] DATA_MAX = 32'h3_0000,
    parameter [31:0] PRELOAD_CHUNK = 32'h1_0000,
    parameter [31:0] TIMEOUT_CYCLES = 32'd222_750_000,  // 3 s
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
    input wire        track_req,     // pulse
    input wire [15:0] track_num,
    input wire        sector_req,    // pulse
    input wire [21:0] sector_num,

    output reg        track_done = 0,     // pulse
    output reg [31:0] track_size = 0,
    output reg        track_missing = 0,
    output reg        sector_ready = 0,   // pulse, 512 words are in the FIFO

    output reg        enable = 0,         // a .msu file was found
    output reg        booted = 0,         // release the SNES
    output reg [31:0] data_loaded = 0     // bytes of the data file in SRAM
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
  // Sector queue

  reg track_loaded = 0;  // reads for the current track may go ahead
  reg track_open = 0;  // mounted: sectors may be served
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

  localparam [4:0] C_WAIT_RESET = 5'd0;
  localparam [4:0] C_GETFILE = 5'd1;
  localparam [4:0] C_PATH_MSU = 5'd2;
  localparam [4:0] C_OPEN_MSU = 5'd3;
  localparam [4:0] C_DATA_SIZE = 5'd4;
  localparam [4:0] C_PRELOAD = 5'd5;
  localparam [4:0] C_BOOTED = 5'd6;
  localparam [4:0] C_IDLE = 5'd7;
  localparam [4:0] C_MOUNT_WAIT = 5'd8;
  localparam [4:0] C_MOUNT_PATH = 5'd9;
  localparam [4:0] C_MOUNT_OPEN = 5'd10;
  localparam [4:0] C_MOUNT_SIZE = 5'd11;
  localparam [4:0] C_MOUNT_FETCH = 5'd12;
  localparam [4:0] C_MOUNT_LOOP_LO = 5'd13;
  localparam [4:0] C_MOUNT_LOOP_HI = 5'd14;
  localparam [4:0] C_MOUNT_DONE = 5'd15;
  localparam [4:0] C_FETCH = 5'd16;
  localparam [4:0] C_WAIT_CMD = 5'd17;
  localparam [4:0] C_WAIT_PATH = 5'd18;
  localparam [4:0] C_READ_DT = 5'd19;
  localparam [4:0] C_PATH_PCM1 = 5'd20;
  localparam [4:0] C_OPEN_PCM1 = 5'd21;

  reg [4:0] cstate = C_WAIT_RESET;
  reg [4:0] cret = C_WAIT_RESET;
  reg [3:0] wait_cnt = 0;

  reg [2:0] res_err = 0;
  reg res_timeout = 0;
  reg [31:0] dt_value = 0;

  reg track_pending = 0;
  reg [15:0] pending_track = 0;

  reg [31:0] preload_len = 0;
  reg [31:0] preload_offset = 0;
  reg [31:0] preload_last = 0;

  reg [QUEUE_LOG2:0] inflight_n = 0;
  reg [7:0] inflight_gen = 0;
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

  wire [31:0] sector_offset = {fetch_sector, 10'b0};
  wire [31:0] file_left = track_size - sector_offset;

  task start_cmd(input [1:0] kind, input [15:0] slot, input [31:0] offset, input [31:0] addr,
                 input [31:0] length, input [4:0] ret);
    begin
      cmd_kind <= kind;
      cmd_slot <= slot;
      cmd_offset <= offset;
      cmd_addr <= addr;
      cmd_length <= length;
      cmd_start <= 1;
      cret <= ret;
      cstate <= C_WAIT_CMD;
    end
  endtask

  task read_dt(input [7:0] word, input [4:0] ret);
    begin
      own_dt <= 1;
      my_dt_addr <= word;
      wait_cnt <= 0;
      cret <= ret;
      cstate <= C_READ_DT;
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

    if (track_req) begin
      track_pending <= 1;
      pending_track <= track_num;
    end
    if (sector_req) begin
      sector_pending <= 1;
      pending_sector <= sector_num;
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
        fetch_active <= 0;
        loop_valid <= 0;
        res_timeout <= 0;
        flush_requested <= 0;
        if (reset_n) begin
          start_cmd(CMD_GETFILE, ROM_SLOT, 0, 0, 0, C_GETFILE);
        end
      end

      C_GETFILE: begin
        if (res_err != 0) cstate <= C_BOOTED;
        else begin
          path_pcm <= 0;
          path_start <= 1;
          cret <= C_PATH_MSU;
          cstate <= C_WAIT_PATH;
        end
      end

      C_PATH_MSU: begin
        if (~path_ok) cstate <= C_BOOTED;
        else start_cmd(CMD_OPENFILE, DATA_SLOT, 0, 0, 0, C_OPEN_MSU);
      end

      C_OPEN_MSU: begin
        if (res_err != 0) begin
          // No <name>.msu that opens: look for track 1
          path_pcm <= 1;
          path_track <= 16'd1;
          path_start <= 1;
          cret <= C_PATH_PCM1;
          cstate <= C_WAIT_PATH;
        end else begin
          read_dt(DATA_SIZE_WORD, C_DATA_SIZE);
        end
      end

      C_PATH_PCM1: begin
        if (~path_ok) cstate <= C_BOOTED;
        else start_cmd(CMD_OPENFILE, AUDIO_SLOT, 0, 0, 0, C_OPEN_PCM1);
      end

      C_OPEN_PCM1: begin
        // Neither file: not an MSU-1 game
        if (res_err == 0) enable <= 1;
        cstate <= C_BOOTED;
      end

      C_DATA_SIZE: begin
        enable <= 1;
        preload_len <= dt_value > DATA_MAX ? DATA_MAX : dt_value;
        preload_offset <= 0;
        cstate <= C_PRELOAD;
      end

      C_PRELOAD: begin
        if (res_err != 0) begin
          // The last read failed: keep what arrived before it
          data_loaded <= preload_offset - preload_last;
          cstate <= C_BOOTED;
        end else if (preload_offset >= preload_len) begin
          data_loaded <= preload_offset;
          cstate <= C_BOOTED;
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
                    C_PRELOAD);
        end
      end

      C_BOOTED: begin
        booted <= 1;
        cstate <= C_IDLE;
      end

      C_IDLE: begin
        if (track_pending) begin
          track_pending <= 0;
          track_open <= 0;
          track_loaded <= 0;
          if (res_timeout) begin
            // APF stopped answering, so nothing more can be read. Report the
            // track missing: the game falls back to its own music.
            res_err <= 3'd7;
            cstate <= C_MOUNT_DONE;
          end else begin
            cstate <= C_MOUNT_WAIT;
          end
        end else if (res_timeout) begin
          // Nothing can be issued any more
        end else if (flush_requested) begin
          flush_requested <= 0;
          flush <= 1;
          flush_sector <= pending_sector;
        end else if (fetch_wanted && ~flush && push_n == 0) begin
          // (push_n: the last read's sectors reach count and fetch_sector
          // only in the next cycle)
          inflight_n <= fetch_n;
          inflight_gen <= gen;
          start_cmd(CMD_READ, AUDIO_SLOT, sector_offset,
                    32'h3000_0000 + {{(22 - QUEUE_LOG2) {1'b0}}, tail_slot, 10'b0},
                    fetch_sector + fetch_n - 1 == last_sector ? file_left : {fetch_n, 10'b0},
                    C_FETCH);
        end
      end

      C_FETCH: begin
        if (res_err == 0 && inflight_gen == gen && ~flush) push_n <= inflight_n;
        else if (res_err != 0) fetch_active <= 0;
        cstate <= C_IDLE;
      end

      // ---- Mounting a track ----
      C_MOUNT_WAIT: begin
        // Let a sector being served finish before the queue is reset
        if (sstate == S_IDLE) begin
          path_pcm <= 1;
          path_track <= pending_track;
          path_start <= 1;
          cret <= C_MOUNT_PATH;
          cstate <= C_WAIT_PATH;
        end
      end

      C_MOUNT_PATH: begin
        if (~path_ok) begin
          res_err <= 3'd4;
          cstate <= C_MOUNT_DONE;
        end else begin
          start_cmd(CMD_OPENFILE, AUDIO_SLOT, 0, 0, 0, C_MOUNT_OPEN);
        end
      end

      C_MOUNT_OPEN: begin
        if (res_err != 0) cstate <= C_MOUNT_DONE;
        else read_dt(AUDIO_SIZE_WORD, C_MOUNT_SIZE);
      end

      C_MOUNT_SIZE: begin
        if (dt_value < 32'd8) begin
          // Not even the 8-byte header
          res_err <= 3'd4;
          cstate <= C_MOUNT_DONE;
        end else begin
          track_size <= dt_value;
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
          inflight_n <= fetch_n;
          inflight_gen <= gen;
          start_cmd(CMD_READ, AUDIO_SLOT, 0, 32'h3000_0000,
                    fetch_n - 1 == last_sector ? track_size : {fetch_n, 10'b0}, C_MOUNT_LOOP_LO);
        end else begin
          cstate <= C_MOUNT_DONE;
        end
      end

      // Bytes 4-7 of the file: the loop point in samples
      C_MOUNT_LOOP_LO: begin
        if (res_err != 0) begin
          cstate <= C_MOUNT_DONE;
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
            res_err <= 0;
            cstate <= C_MOUNT_DONE;
          end
        end
      end

      C_MOUNT_DONE: begin
        track_missing <= res_err != 0;
        if (res_err != 0) begin
          track_loaded <= 0;
          track_size <= 0;
        end else begin
          track_open <= 1;
        end
        track_done <= 1;
        cstate <= C_IDLE;
      end

      // ---- Subroutines ----
      C_WAIT_CMD: begin
        if (cmd_done) begin
          res_err <= cmd_err;
          if (cmd_timeout) res_timeout <= 1;
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
        if (sector_pending && ~flush && ~flush_requested) begin
          if (~track_open || res_timeout || pending_sector > last_sector) begin
            // Nothing to play: silence rather than a stuck msu_audio
            sstate <= S_ZERO;
          end else if (pop || push_n != 0) begin
            // The queue changes this cycle: decide in the next
          end else if (count != 0 && head_sector == pending_sector) begin
            sstate <= S_READ;
          end else if (count == 0 && fetch_active && fetch_sector == pending_sector) begin
            // On its way
          end else begin
            flush_requested <= 1;
          end
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
