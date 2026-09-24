// MSU-1 phase 0 probe (debug builds only, core_top parameter MSU_PROBE).
//
// Runs once after APF takes the core out of reset and measures how the Pocket
// firmware handles the target commands MSU-1 support depends on:
// 0x0190 (get a slot's file path), 0x0192 (open a file into a slot) and
// 0x0180 (read from a slot). The SNES is held in reset meanwhile.
//
// Results go to two places:
//   * a 4 KB log exposed at bridge 0x5000_0000 as a nonvolatile data slot, so
//     APF writes it to the SD card when the core exits
//   * the first 48 results as hex on an on-screen overlay
// tools/msu_probe.py decodes the log. The layout below must match it.
//
// Files it uses, all derived from the ROM's own path "<dir>/<name>.sfc":
//   <name>.msu        opened into slot 21
//   <name>-1.pcm      opened into slot 20 (read-only slot) and 22 (reloadable)
//   <name>-100.pcm    opened to time a lookup late in a large directory
//   <name>-65535.pcm  must not exist
// tools/msu_probe.py generates a matching set with a checkable data pattern.

module msu_probe #(
    parameter [15:0] ROM_SLOT = 16'd0,
    parameter [15:0] PCM_SLOT_RO = 16'd20,
    parameter [15:0] MSU_SLOT = 16'd21,
    parameter [15:0] PCM_SLOT_RW = 16'd22,
    parameter [31:0] TIMEOUT_CYCLES = 32'd742_500_000,
    parameter int DT_LATENCY = 4
) (
    input wire clk,  // clk_74a
    input wire pll_core_locked,
    input wire reset_n,  // from core_bridge_cmd: high once APF has released the core
    input wire bridge_endian_little,

    // core_bridge_cmd target command interface
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

    // Bridge: read data sink at 0x6xxxxxxx, log readback at 0x5xxxxxxx
    input  wire [31:0] bridge_addr,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_rd,
    output reg  [31:0] log_rd_data = 0,

    // Overlay character RAM
    output reg        scr_we = 0,
    output reg [ 9:0] scr_addr = 0,
    output reg [ 7:0] scr_data = 0,

    input wire button_start,

    // Set once START is pressed after the probe finished
    output reg released = 0,
    output wire overlay_en
);
  assign overlay_en = ~released;

  // ---------------------------------------------------------------------------
  // Log layout (32-bit words, written to the file little-endian)

  localparam [31:0] LOG_MAGIC = 32'h5055534D;  // "MSUP"
  localparam [31:0] LOG_VERSION = 32'd1;

  localparam [9:0] L_RESULTS = 10'h002;  // 64 results
  localparam [9:0] L_SNAP_BOOT = 10'h048;  // datatable words 0-63
  localparam [9:0] L_SNAP_MSU = 10'h088;
  localparam [9:0] L_SNAP_P20 = 10'h0C8;
  localparam [9:0] L_SNAP_P22 = 10'h108;
  localparam [9:0] L_SNAP_END = 10'h148;
  localparam [9:0] L_RESP_ROM = 10'h188;  // 0x0190 responses, 64 words each
  localparam [9:0] L_RESP_EMPTY = 10'h1C8;
  localparam [9:0] L_RESP_MSU = 10'h208;
  localparam [9:0] L_PARAM_MSU = 10'h248;  // 0x0192 parameter structs, 66 words
  localparam [9:0] L_PARAM_PCM = 10'h290;
  localparam [9:0] L_TP_READS = 10'h2D8;  // 5 sizes x 16 read times
  localparam [9:0] L_RND = 10'h328;  // 8 times, then 8 {words, err}
  localparam [9:0] L_ALT = 10'h338;  // 32 times, then 32 {words, err}
  localparam [9:0] L_SIZE = 10'h378;  // 40 x {offset, {words, err}}

  // Result indices. 0-47 are also shown on screen, two per row.
  localparam [5:0] R_STATUS = 0;  // [31] done [30] aborted [7:0] last step
  localparam [5:0] R_TOTAL = 1;  // probe run time, units of 1024 cycles
  localparam [5:0] R_BOOT = 2;  // PLL lock to reset_n, cycles
  localparam [5:0] R_FIRST = 3;  // reset_n to first command complete
  localparam [5:0] R_GF_ROM = 4;  // 0x0190 slot 0: err, time
  localparam [5:0] R_GF_EMPTY = 6;  // 0x0190 on an empty deferload slot
  localparam [5:0] R_OPEN_MSU = 8;  // 0x0192 <name>.msu into slot 21
  localparam [5:0] R_GF_MSU = 10;  // 0x0190 slot 21 after the open
  localparam [5:0] R_OPEN_RO = 12;  // 0x0192 <name>-1.pcm into slot 20
  localparam [5:0] R_OPEN_RW = 14;  // 0x0192 <name>-1.pcm into slot 22
  localparam [5:0] R_OPEN_MISS = 16;  // 0x0192 <name>-65535.pcm
  localparam [5:0] R_OPEN_100 = 18;  // 0x0192 <name>-100.pcm
  localparam [5:0] R_REOPEN = 20;  // 0x0192 <name>-1.pcm again
  localparam [5:0] R_READ_SLOT = 22;
  localparam [5:0] R_PAT_MISM = 23;
  localparam [5:0] R_TP = 24;  // 5 x {total, max} for 4/8/16/32/64 KB
  localparam [5:0] R_TP_ERR = 34;
  localparam [5:0] R_RND = 35;  // total, max
  localparam [5:0] R_ALT = 37;  // total, max
  localparam [5:0] R_SIZE_OFS = 39;
  localparam [5:0] R_SIZE_N = 40;
  localparam [5:0] R_SIZE_T = 41;
  localparam [5:0] R_CROSS = 42;  // each {words[23:0], 5'b0, err}
  localparam [5:0] R_CLAMP_A = 43;
  localparam [5:0] R_CLAMP_B = 44;
  localparam [5:0] R_CLAMP_C = 45;
  localparam [5:0] R_FAR = 46;
  localparam [5:0] R_DT_END = 47;  // datatable size of slots 20, 21, 22
  localparam [5:0] R_FIRST_RAW = 50;
  localparam [5:0] R_MISM_OFS = 51;
  localparam [5:0] R_MISM_DATA = 52;
  localparam [5:0] R_PATH_MSU = 53;  // {ok, length}
  localparam [5:0] R_PATH_PCM = 54;
  localparam [5:0] R_ENDIAN = 55;
  localparam [5:0] R_DT_BOOT = 56;  // datatable size of slots 20, 21, 22
  localparam [5:0] R_ALT_ERR = 59;
  localparam [5:0] R_RND_ERR = 60;
  localparam [5:0] R_SIZE_EST = 61;

  // Commands
  localparam [1:0] CMD_READ = 2'd0;
  localparam [1:0] CMD_GETFILE = 2'd1;
  localparam [1:0] CMD_OPENFILE = 2'd2;

  localparam [31:0] SINK_ADDR = 32'h6000_0000;

  // Pattern tags used by tools/msu_probe.py
  localparam [3:0] TAG_PCM = 4'h1;
  localparam [3:0] TAG_MSU = 4'h2;

  // ---------------------------------------------------------------------------
  // Free-running time base

  reg [31:0] now = 0;
  always @(posedge clk) now <= now + 1;

  // ---------------------------------------------------------------------------
  // Target commands

  reg cmd_start = 0;
  reg [1:0] cmd_kind = 0;
  reg [15:0] cmd_slot = 0;
  reg [31:0] cmd_offset = 0;
  reg [31:0] cmd_length = 0;

  wire cmd_done;
  wire [2:0] cmd_err;
  wire cmd_timeout;
  wire [31:0] cmd_cycles;

  msu_tgt_cmd #(
      .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
  ) tgt_cmd (
      .clk  (clk),
      .reset(1'b0),

      .start(cmd_start),
      .cmd(cmd_kind),
      .slot_id(cmd_slot),
      .offset(cmd_offset),
      .bridge_addr(SINK_ADDR),
      .length(cmd_length),

      .busy(),
      .done(cmd_done),
      .err(cmd_err),
      .timeout(cmd_timeout),
      .cycles(cmd_cycles),

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
  // Read sink

  reg sink_arm = 0;
  reg [3:0] sink_tag = 0;
  reg sink_clear = 0;

  wire [31:0] sink_words;
  wire [31:0] sink_mismatches;
  wire [31:0] sink_first_raw;
  wire [31:0] sink_mism_offset;
  wire [31:0] sink_mism_data;

  msu_read_sink read_sink (
      .clk(clk),

      .bridge_wr(bridge_wr),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .bridge_endian_little(bridge_endian_little),

      .arm(sink_arm),
      .file_base(cmd_offset),
      .tag(sink_tag),
      .clear_stats(sink_clear),

      .words(sink_words),
      .mismatches(sink_mismatches),
      .first_raw(sink_first_raw),
      .first_raw_valid(),
      .first_mism_offset(sink_mism_offset),
      .first_mism_data(sink_mism_data),
      .first_mism_valid()
  );

  // ---------------------------------------------------------------------------
  // Path builder, sharing the datatable port

  reg path_start = 0;
  reg path_pcm = 0;
  reg [15:0] path_track = 0;
  wire path_busy;
  wire path_done;
  wire path_ok;
  wire [8:0] path_length;

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
      .length(path_length),

      .dt_addr (path_dt_addr),
      .dt_wren (path_dt_wren),
      .dt_wdata(path_dt_wdata),
      .dt_q    (dt_q)
  );

  reg own_dt = 0;
  assign dt_own = own_dt | path_busy;

  reg [7:0] my_dt_addr = 0;
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
  // Log RAM. APF reads it like the save slot: the word for a read strobe is
  // fetched after the strobe and returned on the following transaction.

  reg log_we = 0;
  reg [9:0] log_waddr = 0;
  reg [31:0] log_wdata = 0;

  reg [31:0] log_mem[0:1023];
  reg [31:0] log_q = 0;
  reg [9:0] log_raddr = 0;
  reg [1:0] log_rd_pipe = 0;

  always @(posedge clk) begin
    if (log_we) log_mem[log_waddr] <= log_wdata;
    log_q <= log_mem[log_raddr];
  end

  always @(posedge clk) begin
    log_rd_pipe <= {log_rd_pipe[0], 1'b0};

    if (bridge_rd && bridge_addr[31:28] == 4'h5) begin
      log_raddr   <= bridge_addr[11:2];
      log_rd_pipe <= 2'b01;
    end

    if (log_rd_pipe[1]) begin
      log_rd_data <= bridge_endian_little ? log_q :
          {log_q[7:0], log_q[15:8], log_q[23:16], log_q[31:24]};
    end
  end

  // ---------------------------------------------------------------------------
  // Screen template

  reg [9:0] tmpl_addr = 0;
  wire [7:0] tmpl_q;

  msu_probe_template template (
      .clk (clk),
      .addr(tmpl_addr),
      .q   (tmpl_q)
  );

  function automatic [7:0] hex_char(input [3:0] nibble);
    hex_char = nibble < 4'd10 ? "0" + nibble : "A" + nibble - 4'd10;
  endfunction

  function automatic [7:0] printable(input [7:0] c);
    printable = (c >= 8'h20 && c < 8'h7F) ? c : ".";
  endfunction

  // ---------------------------------------------------------------------------
  // Sequencer

  localparam [4:0] S_BOOT = 5'd0;
  localparam [4:0] S_TEMPLATE = 5'd1;
  localparam [4:0] S_PROGRESS = 5'd2;
  localparam [4:0] S_STEP = 5'd3;
  localparam [4:0] S_CMD = 5'd4;
  localparam [4:0] S_CMD_WAIT = 5'd5;
  localparam [4:0] S_PATH_WAIT = 5'd6;
  localparam [4:0] S_COPY_READ = 5'd7;
  localparam [4:0] S_COPY_WAIT = 5'd8;
  localparam [4:0] S_COPY_WRITE = 5'd9;
  localparam [4:0] S_STORE = 5'd10;
  localparam [4:0] S_STORE_HEX = 5'd11;
  localparam [4:0] S_SCRPATH_READ = 5'd12;
  localparam [4:0] S_SCRPATH_WAIT = 5'd13;
  localparam [4:0] S_SCRPATH_CHAR = 5'd14;
  localparam [4:0] S_DONE = 5'd15;
  localparam [4:0] S_RELEASED = 5'd16;
  localparam [4:0] S_WAIT_RESET = 5'd17;

  reg [4:0] state = S_BOOT;
  reg [4:0] ret_state = S_BOOT;
  reg [7:0] step = 0;
  reg [3:0] wait_cnt = 0;

  reg prev_locked = 0;
  reg [31:0] lock_time = 0;
  reg [31:0] release_time = 0;
  reg aborted = 0;

  // Outcome of the last command
  reg [2:0] res_err = 0;
  reg [31:0] res_cycles = 0;
  reg [31:0] res_words = 0;

  wire [31:0] res_packed = {res_words[23:0], 5'b0, res_err};
  wire read_ok_4k = res_err == 0 && res_words == 32'd1024;

  // Store: up to 3 values to consecutive results, or to raw log addresses
  reg [5:0] st_idx = 0;
  reg [9:0] st_log_addr = 0;
  reg st_raw = 0;
  reg [31:0] st_val[0:2];
  reg [1:0] st_count = 0;
  reg [1:0] st_pos = 0;
  reg [2:0] hex_pos = 0;

  wire [5:0] st_cur = st_idx + st_pos;
  wire [9:0] st_scr_base = {st_cur[5:1] + 5'd4, 5'd0} + (st_cur[0] ? 10'd18 : 10'd4);

  // Copy from the datatable to the log
  reg [7:0] cp_src = 0;
  reg [9:0] cp_dst = 0;
  reg [6:0] cp_n = 0;
  reg [6:0] cp_i = 0;
  reg cp_snapshot = 0;
  reg [31:0] cp_prev = 0;
  reg [31:0] dt_size20 = 0;
  reg [31:0] dt_size21 = 0;
  reg [31:0] dt_size22 = 0;

  // ROM path to screen
  reg [4:0] sp_word = 0;
  reg [1:0] sp_byte = 0;
  reg [31:0] sp_hold = 0;
  reg sp_ended = 0;
  wire [7:0] sp_char = sp_hold[31-8*sp_byte-:8];

  // Test state
  reg [15:0] read_slot = 0;
  reg [15:0] other_slot = 0;
  reg read_slot_ok = 0;
  reg msu_ok = 0;
  reg path_msu_ok = 0;

  reg [2:0] tp_k = 0;
  reg [7:0] tp_n = 0;
  reg [31:0] tp_total = 0;
  reg [31:0] tp_max = 0;
  reg [31:0] tp_err = 0;

  reg [4:0] loop_i = 0;
  reg [31:0] loop_total = 0;
  reg [31:0] loop_max = 0;
  reg [31:0] loop_err = 0;

  reg [31:0] sz_lo = 0;
  reg [31:0] sz_bad = 0;
  reg [31:0] sz_probe = 0;
  reg sz_expanding = 0;
  reg [5:0] sz_n = 0;
  reg [31:0] sz_total = 0;
  reg [31:0] size_est = 0;

  wire [31:0] sz_mid = ((sz_lo + sz_bad) >> 1) & 32'hFFFF_F000;

  function [31:0] rnd_offset(input [2:0] i);
    case (i)
      3'd0: rnd_offset = 32'h00F0_0000;  // 15 MB
      3'd1: rnd_offset = 32'h0010_0000;  // 1 MB
      3'd2: rnd_offset = 32'h0080_0000;
      3'd3: rnd_offset = 32'h00C0_0000;
      3'd4: rnd_offset = 32'h0040_0000;
      3'd5: rnd_offset = 32'h0000_0000;
      3'd6: rnd_offset = 32'h00E0_0000;
      default: rnd_offset = 32'h0060_0000;
    endcase
  endfunction

  // Step program helpers. Each sets up one action; the action returns to
  // S_PROGRESS, which runs the step in `step`.
  task do_cmd(input [1:0] kind, input [15:0] slot, input [31:0] offset, input [31:0] length,
              input [3:0] tag);
    begin
      cmd_kind <= kind;
      cmd_slot <= slot;
      cmd_offset <= offset;
      cmd_length <= length;
      sink_tag <= tag;
      sink_arm <= 1;
      ret_state <= S_PROGRESS;
      state <= S_CMD;
    end
  endtask

  task do_store(input [5:0] idx, input [1:0] count, input [31:0] v0, input [31:0] v1,
                input [31:0] v2);
    begin
      st_idx <= idx;
      st_raw <= 0;
      st_count <= count;
      st_val[0] <= v0;
      st_val[1] <= v1;
      st_val[2] <= v2;
      st_pos <= 0;
      ret_state <= S_PROGRESS;
      state <= S_STORE;
    end
  endtask

  task do_store_raw(input [9:0] addr, input [1:0] count, input [31:0] v0, input [31:0] v1);
    begin
      st_log_addr <= addr;
      st_raw <= 1;
      st_count <= count;
      st_val[0] <= v0;
      st_val[1] <= v1;
      st_pos <= 0;
      ret_state <= S_PROGRESS;
      state <= S_STORE;
    end
  endtask

  task do_copy(input [7:0] src, input [9:0] dst, input [6:0] n, input snapshot);
    begin
      cp_src <= src;
      cp_dst <= dst;
      cp_n <= n;
      cp_i <= 0;
      cp_snapshot <= snapshot;
      own_dt <= 1;
      ret_state <= S_PROGRESS;
      state <= S_COPY_READ;
    end
  endtask

  task do_path(input pcm, input [15:0] track);
    begin
      path_pcm <= pcm;
      path_track <= track;
      path_start <= 1;
      ret_state <= S_PROGRESS;
      state <= S_PATH_WAIT;
    end
  endtask

  always @(posedge clk) begin
    cmd_start <= 0;
    path_start <= 0;
    sink_arm <= 0;
    sink_clear <= 0;
    log_we <= 0;
    scr_we <= 0;

    prev_locked <= pll_core_locked;
    if (pll_core_locked && ~prev_locked) lock_time <= now;


    case (state)
      S_BOOT: begin
        // Quartus may pick any power-up value for a register that only ever
        // changes one way, and then treats it as a constant. These flags get
        // an explicit clear so they stay real registers.
        released <= 0;
        aborted <= 0;
        tmpl_addr <= 0;
        state <= S_TEMPLATE;
      end

      // Copy the screen template into the overlay RAM, so the labels show even
      // if APF never releases the core. The ROM output is one cycle behind its
      // address.
      S_TEMPLATE: begin
        tmpl_addr <= tmpl_addr + 1;
        if (tmpl_addr != 0) begin
          scr_we   <= 1;
          scr_addr <= tmpl_addr - 1;
          scr_data <= tmpl_q;
        end
        if (tmpl_addr == 10'd1023) begin
          log_we <= 1;
          log_waddr <= 0;
          log_wdata <= LOG_MAGIC;
          state <= S_WAIT_RESET;
        end
      end

      // APF releases the core once the loader has finished
      S_WAIT_RESET: begin
        if (reset_n) begin
          release_time <= now;
          step <= 0;
          state <= S_PROGRESS;
        end
      end

      // Show the step number at the top right, then run the step
      S_PROGRESS: begin
        scr_we <= 1;
        if (wait_cnt == 0) begin
          scr_addr <= 10'd30;
          scr_data <= hex_char(step[7:4]);
          wait_cnt <= 1;
        end else begin
          scr_addr <= 10'd31;
          scr_data <= hex_char(step[3:0]);
          wait_cnt <= 0;
          state <= S_STEP;
        end
      end

      S_STEP: begin
        case (step)
          // ---- Boot state ----------------------------------------------------
          8'd0: begin
            log_we <= 1;
            log_waddr <= 1;
            log_wdata <= LOG_VERSION;
            sink_clear <= 1;
            do_store(R_BOOT, 1, release_time - lock_time, 0, 0);
            step <= 8'd1;
          end
          8'd1: begin
            do_copy(8'd0, L_SNAP_BOOT, 7'd64, 1);
            step <= 8'd2;
          end
          8'd2: begin
            do_store(R_DT_BOOT, 3, dt_size20, dt_size21, dt_size22);
            step <= 8'd3;
          end

          // ---- 0x0190 on an empty deferload slot ---------------------------
          // First, because every 0x0190 overwrites the response struct the
          // paths are built from
          8'd3: begin
            do_cmd(CMD_GETFILE, PCM_SLOT_RO, 0, 0, 0);
            step <= 8'd4;
          end
          8'd4: begin
            do_store(R_FIRST, 1, now - release_time, 0, 0);
            step <= 8'd5;
          end
          8'd5: begin
            do_store(R_GF_EMPTY, 2, res_err, res_cycles, 0);
            step <= 8'd6;
          end
          8'd6: begin
            do_copy(8'd64, L_RESP_EMPTY, 7'd64, 0);
            step <= 8'd7;
          end

          // ---- P1: full path of the ROM (0x0190 on slot 0) ------------------
          8'd7: begin
            do_cmd(CMD_GETFILE, ROM_SLOT, 0, 0, 0);
            step <= 8'd8;
          end
          8'd8: begin
            do_store(R_GF_ROM, 2, {23'b0, bridge_endian_little, 5'b0, res_err}, res_cycles, 0);
            step <= 8'd9;
          end
          8'd9: begin
            do_copy(8'd64, L_RESP_ROM, 7'd64, 0);
            step <= 8'd10;
          end
          8'd10: begin
            own_dt <= 1;
            sp_word <= 0;
            sp_ended <= 0;
            ret_state <= S_PROGRESS;
            state <= S_SCRPATH_READ;
            step <= 8'd11;
          end

          // ---- P2: open <name>.msu into slot 21 ------------------------------
          8'd11: begin
            do_path(0, 0);
            step <= 8'd12;
          end
          8'd12: begin
            path_msu_ok <= path_ok;
            do_store(R_PATH_MSU, 1, {15'b0, path_ok, 7'b0, path_length}, 0, 0);
            step <= 8'd13;
          end
          8'd13: begin
            do_copy(8'd128, L_PARAM_MSU, 7'd66, 0);
            step <= 8'd14;
          end
          8'd14: begin
            if (path_msu_ok) begin
              do_cmd(CMD_OPENFILE, MSU_SLOT, 0, 0, 0);
              step <= 8'd15;
            end else begin
              // 0x80: no path could be built
              do_store(R_OPEN_MSU, 2, 32'h80, 0, 0);
              step <= 8'd16;
            end
          end
          8'd15: begin
            msu_ok <= res_err == 0;
            do_store(R_OPEN_MSU, 2, res_err, res_cycles, 0);
            step <= 8'd16;
          end
          8'd16: begin
            do_copy(8'd0, L_SNAP_MSU, 7'd64, 1);
            step <= 8'd19;
          end

          // ---- P2/P3: open <name>-1.pcm into a read-only and a reloadable slot
          8'd19: begin
            do_path(1, 16'd1);
            step <= 8'd20;
          end
          8'd20: begin
            do_store(R_PATH_PCM, 1, {15'b0, path_ok, 7'b0, path_length}, 0, 0);
            step <= 8'd21;
          end
          8'd21: begin
            do_copy(8'd128, L_PARAM_PCM, 7'd66, 0);
            step <= 8'd22;
          end
          8'd22: begin
            do_cmd(CMD_OPENFILE, PCM_SLOT_RO, 0, 0, 0);
            step <= 8'd23;
          end
          8'd23: begin
            read_slot <= PCM_SLOT_RO;
            other_slot <= PCM_SLOT_RW;
            read_slot_ok <= res_err == 0;
            do_store(R_OPEN_RO, 2, res_err, res_cycles, 0);
            step <= 8'd24;
          end
          8'd24: begin
            do_copy(8'd0, L_SNAP_P20, 7'd64, 1);
            step <= 8'd25;
          end
          8'd25: begin
            do_cmd(CMD_OPENFILE, PCM_SLOT_RW, 0, 0, 0);
            step <= 8'd26;
          end
          8'd26: begin
            if (~read_slot_ok && res_err == 0) begin
              // Only the reloadable slot accepted the file: read from it
              read_slot <= PCM_SLOT_RW;
              other_slot <= PCM_SLOT_RO;
              read_slot_ok <= 1;
            end
            do_store(R_OPEN_RW, 2, res_err, res_cycles, 0);
            step <= 8'd27;
          end
          8'd27: begin
            do_copy(8'd0, L_SNAP_P22, 7'd64, 1);
            step <= 8'd28;
          end
          8'd28: begin
            do_store(R_READ_SLOT, 1, {read_slot_ok, 15'b0, read_slot}, 0, 0);
            step <= 8'd29;
          end

          // ---- P2: a missing file, and one late in a large directory ---------
          8'd29: begin
            do_path(1, 16'd65535);
            step <= 8'd30;
          end
          8'd30: begin
            do_cmd(CMD_OPENFILE, other_slot, 0, 0, 0);
            step <= 8'd31;
          end
          8'd31: begin
            do_store(R_OPEN_MISS, 2, res_err, res_cycles, 0);
            step <= 8'd32;
          end
          8'd32: begin
            do_path(1, 16'd100);
            step <= 8'd33;
          end
          8'd33: begin
            do_cmd(CMD_OPENFILE, other_slot, 0, 0, 0);
            step <= 8'd34;
          end
          8'd34: begin
            do_store(R_OPEN_100, 2, res_err, res_cycles, 0);
            step <= 8'd35;
          end
          8'd35: begin
            do_path(1, 16'd1);
            step <= 8'd36;
          end
          8'd36: begin
            // Reopen the file that is already open in the read slot
            do_cmd(CMD_OPENFILE, read_slot, 0, 0, 0);
            step <= 8'd37;
          end
          8'd37: begin
            do_store(R_REOPEN, 2, res_err, res_cycles, 0);
            step <= read_slot_ok ? 8'd38 : 8'd78;
          end

          // ---- P5: sequential throughput, 512 KB each at 4/8/16/32/64 KB ----
          8'd38: begin
            tp_k <= 0;
            tp_err <= 0;
            step <= 8'd39;
            state <= S_PROGRESS;
          end
          8'd39: begin
            tp_n <= 0;
            tp_total <= 0;
            tp_max <= 0;
            step <= 8'd40;
            state <= S_PROGRESS;
          end
          8'd40: begin
            do_cmd(CMD_READ, read_slot, {10'b0, tp_k, 19'b0} + ({24'b0, tp_n} << (12 + tp_k)),
                   32'd4096 << tp_k, TAG_PCM);
            step <= 8'd41;
          end
          8'd41: begin
            tp_total <= tp_total + res_cycles;
            if (res_cycles > tp_max) tp_max <= res_cycles;
            if (res_err != 0 || res_words != (32'd1024 << tp_k)) tp_err <= tp_err + 1;
            tp_n <= tp_n + 1;

            if (tp_n < 16) do_store_raw(L_TP_READS + {tp_k, 4'b0} + tp_n[3:0], 1, res_cycles, 0);
            else state <= S_PROGRESS;

            step <= (tp_n + 8'd1 == (8'd128 >> tp_k)) ? 8'd42 : 8'd40;
          end
          8'd42: begin
            do_store(R_TP + {tp_k, 1'b0}, 2, tp_total, tp_max, 0);
            tp_k <= tp_k + 1;
            step <= (tp_k == 3'd4) ? 8'd43 : 8'd39;
          end

          // ---- P5: 4 KB reads at scattered offsets ---------------------------
          8'd43: begin
            loop_i <= 0;
            loop_total <= 0;
            loop_max <= 0;
            loop_err <= 0;
            step <= 8'd44;
            state <= S_PROGRESS;
          end
          8'd44: begin
            do_cmd(CMD_READ, read_slot, rnd_offset(loop_i[2:0]), 32'd4096, TAG_PCM);
            step <= 8'd45;
          end
          8'd45: begin
            loop_total <= loop_total + res_cycles;
            if (res_cycles > loop_max) loop_max <= res_cycles;
            if (~read_ok_4k) loop_err <= loop_err + 1;
            do_store_raw(L_RND + loop_i[2:0], 1, res_cycles, 0);
            step <= 8'd46;
          end
          8'd46: begin
            do_store_raw(L_RND + 10'd8 + loop_i[2:0], 1, res_packed, 0);
            loop_i <= loop_i + 1;
            step <= (loop_i == 5'd7) ? 8'd47 : 8'd44;
          end
          8'd47: begin
            do_store(R_RND, 2, loop_total, loop_max, 0);
            step <= 8'd48;
          end
          8'd48: begin
            do_store(R_RND_ERR, 1, loop_err, 0, 0);
            loop_i <= 0;
            loop_total <= 0;
            loop_max <= 0;
            loop_err <= 0;
            step <= msu_ok ? 8'd49 : 8'd53;
          end

          // ---- P6: alternate 4 KB reads between the .pcm and .msu slots ------
          8'd49: begin
            if (~loop_i[0])
              do_cmd(CMD_READ, read_slot, 32'h0030_0000 + {loop_i[4:1], 12'b0}, 32'd4096,
                     TAG_PCM);
            else
              do_cmd(CMD_READ, MSU_SLOT, 32'h0002_0000 + {loop_i[4:1], 12'b0}, 32'd4096,
                     TAG_MSU);
            step <= 8'd50;
          end
          8'd50: begin
            loop_total <= loop_total + res_cycles;
            if (res_cycles > loop_max) loop_max <= res_cycles;
            if (~read_ok_4k) loop_err <= loop_err + 1;
            do_store_raw(L_ALT + loop_i, 1, res_cycles, 0);
            step <= 8'd51;
          end
          8'd51: begin
            do_store_raw(L_ALT + 10'd32 + loop_i, 1, res_packed, 0);
            loop_i <= loop_i + 1;
            step <= (loop_i == 5'd31) ? 8'd52 : 8'd49;
          end
          8'd52: begin
            do_store(R_ALT, 2, loop_total, loop_max, 0);
            step <= 8'd53;
          end
          8'd53: begin
            do_store(R_ALT_ERR, 1, loop_err, 0, 0);
            step <= 8'd54;
          end

          // ---- P4: find the file size with 4 KB reads ------------------------
          // sz_lo: largest offset known to read fine, sz_bad: smallest known
          // to fail. Doubles from 1 MB, then bisects to 4 KB.
          8'd54: begin
            sz_lo <= 0;
            sz_bad <= 0;
            sz_probe <= 32'h0010_0000;
            sz_expanding <= 1;
            sz_n <= 0;
            sz_total <= 0;
            step <= 8'd55;
            state <= S_PROGRESS;
          end
          8'd55: begin
            do_cmd(CMD_READ, read_slot, sz_probe, 32'd4096, 0);
            step <= 8'd56;
          end
          8'd56: begin
            sz_n <= sz_n + 1;
            sz_total <= sz_total + res_cycles;

            if (read_ok_4k) begin
              sz_lo <= sz_probe;
              if (sz_expanding) begin
                if (sz_probe[30]) begin
                  // 1 GB and still readable: stop there
                  sz_bad <= sz_probe << 1;
                  sz_expanding <= 0;
                end else begin
                  sz_probe <= sz_probe << 1;
                end
              end
            end else begin
              sz_bad <= sz_probe;
              sz_expanding <= 0;
            end

            if (sz_n < 6'd40)
              do_store_raw(L_SIZE + {sz_n[5:0], 1'b0}, 2, sz_probe, res_packed);
            else state <= S_PROGRESS;

            step <= 8'd57;
          end
          8'd57: begin
            if (sz_expanding) step <= 8'd55;
            else if (sz_bad - sz_lo <= 32'd4096 || sz_n >= 6'd40) step <= 8'd58;
            else begin
              sz_probe <= sz_mid;
              step <= 8'd55;
            end
            state <= S_PROGRESS;
          end

          // ---- P4: reads that cross or pass the end of the file ------------
          8'd58: begin
            do_store(R_SIZE_OFS, 3, sz_lo, sz_n, sz_total);
            step <= 8'd59;
          end
          8'd59: begin
            do_cmd(CMD_READ, read_slot, sz_lo + 32'd4096, 32'd4096, 0);
            step <= 8'd60;
          end
          8'd60: begin
            do_store(R_CROSS, 1, res_packed, 0, 0);
            step <= 8'd61;
          end
          8'd61: begin
            // Length 0xFFFFFFFF: APF should clamp it to the end of the file
            do_cmd(CMD_READ, read_slot, sz_lo + 32'd4096, 32'hFFFF_FFFF, 0);
            step <= 8'd62;
          end
          8'd62: begin
            size_est <= sz_lo + 32'd4096 + {res_words[29:0], 2'b00};
            do_store(R_CLAMP_A, 1, res_packed, 0, 0);
            step <= 8'd63;
          end
          8'd63: begin
            do_cmd(CMD_READ, read_slot, size_est, 32'hFFFF_FFFF, 0);
            step <= 8'd64;
          end
          8'd64: begin
            do_store(R_CLAMP_B, 1, res_packed, 0, 0);
            step <= 8'd65;
          end
          8'd65: begin
            do_cmd(CMD_READ, read_slot, sz_lo, 32'hFFFF_FFFF, 0);
            step <= 8'd66;
          end
          8'd66: begin
            do_store(R_CLAMP_C, 1, res_packed, 0, 0);
            step <= 8'd67;
          end
          8'd67: begin
            do_cmd(CMD_READ, read_slot, 32'h7FFF_0000, 32'd4, 0);
            step <= 8'd68;
          end
          8'd68: begin
            do_store(R_FAR, 1, res_packed, 0, 0);
            step <= 8'd69;
          end
          8'd69: begin
            do_store(R_SIZE_EST, 1, size_est, 0, 0);
            step <= 8'd78;
          end

          // ---- 0x0190 on slot 21: does it report the file the core opened?
          8'd78: begin
            do_cmd(CMD_GETFILE, MSU_SLOT, 0, 0, 0);
            step <= 8'd79;
          end
          8'd79: begin
            do_store(R_GF_MSU, 2, res_err, res_cycles, 0);
            step <= 8'd80;
          end
          8'd80: begin
            do_copy(8'd64, L_RESP_MSU, 7'd64, 0);
            step <= 8'd70;
          end

          // ---- Wrap up ------------------------------------------------------
          8'd70: begin
            do_copy(8'd0, L_SNAP_END, 7'd64, 1);
            step <= 8'd71;
          end
          8'd71: begin
            do_store(R_DT_END, 3, dt_size20, dt_size21, dt_size22);
            step <= 8'd72;
          end
          8'd72: begin
            do_store(R_FIRST_RAW, 3, sink_first_raw, sink_mism_offset, sink_mism_data);
            step <= 8'd73;
          end
          8'd73: begin
            do_store(R_PAT_MISM, 1, sink_mismatches, 0, 0);
            step <= 8'd74;
          end
          8'd74: begin
            do_store(R_TP_ERR, 1, tp_err, 0, 0);
            step <= 8'd75;
          end
          8'd75: begin
            do_store(R_ENDIAN, 1, {31'b0, bridge_endian_little}, 0, 0);
            step <= 8'd76;
          end
          8'd76: begin
            do_store(R_STATUS, 2, {1'b1, aborted, 22'b0, step}, (now - release_time) >> 10, 0);
            step <= 8'd77;
          end
          default: begin
            state <= S_DONE;
          end
        endcase
      end

      S_CMD: begin
        if (aborted) begin
          // A command timed out earlier; core_bridge_cmd is still waiting
          // for it, so nothing more can be issued
          res_err <= 3'd7;
          res_cycles <= 0;
          res_words <= 0;
          state <= ret_state;
        end else begin
          cmd_start <= 1;
          state <= S_CMD_WAIT;
        end
      end

      S_CMD_WAIT: begin
        if (cmd_done) begin
          res_err <= cmd_err;
          res_cycles <= cmd_cycles;
          res_words <= sink_words;
          if (cmd_timeout) aborted <= 1;
          state <= ret_state;
        end
      end

      S_PATH_WAIT: begin
        // path_busy rises the cycle after path_start
        if (path_done) state <= ret_state;
      end

      // Copy datatable words [cp_src, cp_src + cp_n) to the log at cp_dst
      S_COPY_READ: begin
        my_dt_addr <= cp_src + cp_i;
        wait_cnt <= 0;
        state <= S_COPY_WAIT;
      end

      S_COPY_WAIT: begin
        wait_cnt <= wait_cnt + 1;
        if (wait_cnt == DT_LATENCY[3:0]) begin
          wait_cnt <= 0;
          state <= S_COPY_WRITE;
        end
      end

      S_COPY_WRITE: begin
        log_we <= 1;
        log_waddr <= cp_dst + cp_i;
        log_wdata <= dt_q;

        // The start of the datatable is APF's {slot id, size} table
        if (cp_snapshot) begin
          if (cp_i[0]) begin
            if (cp_prev == {16'b0, PCM_SLOT_RO}) dt_size20 <= dt_q;
            if (cp_prev == {16'b0, MSU_SLOT}) dt_size21 <= dt_q;
            if (cp_prev == {16'b0, PCM_SLOT_RW}) dt_size22 <= dt_q;
          end
          cp_prev <= dt_q;
        end

        cp_i <= cp_i + 1;
        if (cp_i + 7'd1 == cp_n) begin
          own_dt <= 0;
          state  <= ret_state;
        end else begin
          state <= S_COPY_READ;
        end
      end

      // Write results to the log, and results 0-47 to the screen as hex
      S_STORE: begin
        log_we <= 1;
        log_waddr <= st_raw ? st_log_addr + st_pos : L_RESULTS + st_cur;
        log_wdata <= st_val[st_pos];
        hex_pos <= 0;

        if (~st_raw && st_cur < 6'd48) state <= S_STORE_HEX;
        else if (st_pos + 2'd1 == st_count) state <= ret_state;
        else st_pos <= st_pos + 1;
      end

      S_STORE_HEX: begin
        scr_we <= 1;
        scr_addr <= st_scr_base + hex_pos;
        scr_data <= hex_char(st_val[st_pos][31-4*hex_pos-:4]);
        hex_pos <= hex_pos + 1;

        if (hex_pos == 3'd7) begin
          if (st_pos + 2'd1 == st_count) begin
            state <= ret_state;
          end else begin
            st_pos <= st_pos + 1;
            state  <= S_STORE;
          end
        end
      end

      // ROM path to screen rows 1-3 (96 characters)
      S_SCRPATH_READ: begin
        my_dt_addr <= 8'd64 + sp_word;
        wait_cnt <= 0;
        state <= S_SCRPATH_WAIT;
      end

      S_SCRPATH_WAIT: begin
        wait_cnt <= wait_cnt + 1;
        if (wait_cnt == DT_LATENCY[3:0]) begin
          wait_cnt <= 0;
          sp_hold <= dt_q;
          sp_byte <= 0;
          state <= S_SCRPATH_CHAR;
        end
      end

      S_SCRPATH_CHAR: begin
        scr_we   <= 1;
        scr_addr <= 10'd32 + {3'b0, sp_word, sp_byte};
        if (sp_ended || sp_char == 8'h00) begin
          scr_data <= " ";
          sp_ended <= 1;
        end else begin
          scr_data <= printable(sp_char);
        end

        sp_byte <= sp_byte + 1;
        if (sp_byte == 2'd3) begin
          if (sp_word == 5'd23) begin
            own_dt <= 0;
            state  <= ret_state;
          end else begin
            sp_word <= sp_word + 1;
            state   <= S_SCRPATH_READ;
          end
        end
      end

      S_DONE: begin
        if (button_start) begin
          released <= 1;
          state <= S_RELEASED;
        end
      end

      S_RELEASED: ;

      default: state <= S_BOOT;
    endcase
  end
endmodule
