// MSU-1 for the Pocket: file access (msu_host), SRAM (msu_sram) and the clock
// crossing to the SNES side. Towards MAIN_SNES it behaves like hps_ext.v and
// the ARM on MiSTer:
//   * a track request raises track_mounting until the track is open, then
//     reports its size, or track_missing
//   * each audio_req/audio_seek is answered with an audio_download window of
//     512 16-bit words (one 1 KB sector), audio_ack high while it lasts
//   * data file reads use msu_data_store's toggle handshake, served from SRAM
// It also keeps the MSU-1 event log (msu_log.sv), read over the bridge at
// 0x5xxxxxxx.

module msu_pocket
  import msu_ev::*;
#(
    parameter [15:0] AUDIO_SLOT = 16'd20,
    parameter [15:0] DATA_SLOT = 16'd21,
    parameter [7:0] AUDIO_SIZE_WORD = 8'd5,
    parameter [7:0] DATA_SIZE_WORD = 8'd7,
    parameter int QUEUE_LOG2 = 6,
    parameter [31:0] TIMEOUT_CYCLES = 32'd222_750_000,
    parameter int DT_LATENCY = 4
) (
    input wire clk_74a,
    input wire clk_sys,

    input wire reset_n,     // clk_74a, from core_bridge_cmd
    input wire snes_reset,  // clk_sys

    // core_bridge_cmd target commands (clk_74a)
    output wire        target_dataslot_read,
    output wire        target_dataslot_getfile,
    output wire        target_dataslot_openfile,
    output wire [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output wire [31:0] target_dataslot_bridgeaddr,
    output wire [31:0] target_dataslot_length,
    input  wire        target_dataslot_done,
    input  wire [ 2:0] target_dataslot_err,

    // Datatable port A (clk_74a)
    output wire        dt_own,
    output wire [ 7:0] dt_addr,
    output wire        dt_wren,
    output wire [31:0] dt_wdata,
    input  wire [31:0] dt_q,

    // Bridge (clk_74a)
    input  wire        bridge_wr,
    input  wire        bridge_rd,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    input  wire        bridge_endian_little,
    output wire [31:0] log_rd_data,

    // SRAM
    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,

    output wire booted,  // clk_74a: release the SNES

    // MAIN_SNES (clk_sys)
    output wire        msu_enable,
    input  wire [15:0] msu_track_num,
    input  wire        msu_track_request,
    output reg         msu_track_mounting = 0,
    output reg         msu_track_missing = 0,
    output reg  [31:0] msu_audio_size = 0,
    output reg         msu_audio_ack = 0,
    input  wire        msu_audio_req,
    input  wire        msu_audio_seek,
    input  wire [21:0] msu_audio_sector,
    output reg         msu_audio_download = 0,
    output reg  [15:0] msu_audio_data = 0,
    output reg         msu_audio_data_wr = 0,
    input  wire [28:0] msu_ram_addr,
    input  wire        msu_ram_req,
    output reg         msu_ram_ack = 0,
    output reg  [63:0] msu_ram_dout = 0,

    // For the event log (clk_sys): MAIN_SNES msu_dbg, and vertical blank
    input wire [63:0] msu_dbg,
    input wire        snes_vblank
);
  // Data file store in SRAM, after the sector queue
  localparam [17:0] DATA_BASE = 18'h1_0000;
  localparam [31:0] DATA_MAX = 32'h3_0000;

  wire host_enable;
  wire host_track_done;
  wire [31:0] host_track_size;
  wire host_track_missing;
  wire host_sector_ready;
  wire [31:0] data_loaded;

  wire evc_valid, evs_valid;
  wire [7:0] evc_type, evs_type;
  wire [23:0] evc_data, evs_data;

  // ---------------------------------------------------------------------------
  // Clock crossing: requests are toggles with a payload held stable

  // clk_sys -> clk_74a
  reg tr_tgl = 0, sr_tgl = 0, dq_tgl = 0;
  reg [15:0] tr_num = 0;
  reg [21:0] sr_sector = 0;
  reg [28:0] dq_addr = 0;

  reg [2:0] tr_s = 0, sr_s = 0, dq_s = 0;
  always @(posedge clk_74a) begin
    tr_s <= {tr_s[1:0], tr_tgl};
    sr_s <= {sr_s[1:0], sr_tgl};
    dq_s <= {dq_s[1:0], dq_tgl};
  end
  wire track_req_74 = tr_s[2] ^ tr_s[1];
  wire sector_req_74 = sr_s[2] ^ sr_s[1];
  wire data_req_74 = dq_s[2] ^ dq_s[1];

  // clk_74a -> clk_sys
  reg td_tgl = 0, sd_tgl = 0, dr_tgl = 0;
  reg [31:0] td_size = 0;
  reg td_missing = 0;
  reg [63:0] dr_data = 0;

  reg [2:0] td_s = 0, sd_s = 0, dr_s = 0;
  reg [1:0] enable_s = 0;
  always @(posedge clk_sys) begin
    td_s <= {td_s[1:0], td_tgl};
    sd_s <= {sd_s[1:0], sd_tgl};
    dr_s <= {dr_s[1:0], dr_tgl};
    enable_s <= {enable_s[0], host_enable};
  end
  wire track_done_sys = td_s[2] ^ td_s[1];
  wire sector_ready_sys = sd_s[2] ^ sd_s[1];
  wire data_done_sys = dr_s[2] ^ dr_s[1];

  assign msu_enable = enable_s[1];

  // ---------------------------------------------------------------------------
  // clk_74a side


  wire host_sram_rd;
  wire [16:0] host_sram_addr;
  wire host_sram_done;
  wire [15:0] host_sram_q;

  wire fifo_wr;
  wire [15:0] fifo_wdata;

  msu_host #(
      .AUDIO_SLOT(AUDIO_SLOT),
      .DATA_SLOT(DATA_SLOT),
      .AUDIO_SIZE_WORD(AUDIO_SIZE_WORD),
      .DATA_SIZE_WORD(DATA_SIZE_WORD),
      .QUEUE_LOG2(QUEUE_LOG2),
      .DATA_BASE(DATA_BASE),
      .DATA_MAX(DATA_MAX),
      .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
      .DT_LATENCY(DT_LATENCY)
  ) host (
      .clk(clk_74a),
      .reset_n(reset_n),

      .target_dataslot_read(target_dataslot_read),
      .target_dataslot_getfile(target_dataslot_getfile),
      .target_dataslot_openfile(target_dataslot_openfile),
      .target_dataslot_id(target_dataslot_id),
      .target_dataslot_slotoffset(target_dataslot_slotoffset),
      .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
      .target_dataslot_length(target_dataslot_length),
      .target_dataslot_done(target_dataslot_done),
      .target_dataslot_err(target_dataslot_err),

      .dt_own  (dt_own),
      .dt_addr (dt_addr),
      .dt_wren (dt_wren),
      .dt_wdata(dt_wdata),
      .dt_q    (dt_q),

      .sram_rd  (host_sram_rd),
      .sram_addr(host_sram_addr),
      .sram_done(host_sram_done),
      .sram_q   (host_sram_q),

      .fifo_wr  (fifo_wr),
      .fifo_data(fifo_wdata),

      .track_req (track_req_74),
      .track_num (tr_num),
      .sector_req(sector_req_74),
      .sector_num(sr_sector),

      .track_done(host_track_done),
      .track_size(host_track_size),
      .track_missing(host_track_missing),
      .sector_ready(host_sector_ready),

      .enable(host_enable),
      .booted(booted),
      .data_loaded(data_loaded),

      .evc_valid(evc_valid),
      .evc_type (evc_type),
      .evc_data (evc_data),
      .evs_valid(evs_valid),
      .evs_type (evs_type),
      .evs_data (evs_data)
  );

  always @(posedge clk_74a) begin
    if (host_track_done) begin
      td_size <= host_track_size;
      td_missing <= host_track_missing;
      td_tgl <= ~td_tgl;
    end
    if (host_sector_ready) sd_tgl <= ~sd_tgl;
  end

  // Data port reads: 8 bytes from SRAM, zeros past what was preloaded
  reg data_rd = 0;
  reg [16:0] data_rd_addr = 0;
  wire data_done;
  wire [63:0] data_q;

  always @(posedge clk_74a) begin
    data_rd <= 0;
    if (data_req_74) begin
      if ({dq_addr, 3'b000} < data_loaded) begin
        data_rd <= 1;
        data_rd_addr <= {DATA_BASE[17:1]} + {dq_addr[14:0], 2'b00};
      end else begin
        dr_data <= 0;
        dr_tgl  <= ~dr_tgl;
      end
    end
    if (data_done) begin
      dr_data <= data_q;
      dr_tgl  <= ~dr_tgl;
    end
  end

  msu_sram sram (
      .clk(clk_74a),

      .bridge_wr(bridge_wr),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .bridge_endian_little(bridge_endian_little),

      .data_rd  (data_rd),
      .data_addr(data_rd_addr),
      .data_busy(),
      .data_done(data_done),
      .data_q   (data_q),

      .host_rd  (host_sram_rd),
      .host_addr(host_sram_addr),
      .host_busy(),
      .host_done(host_sram_done),
      .host_q   (host_sram_q),

      .sram_a(sram_a),
      .sram_dq(sram_dq),
      .sram_oe_n(sram_oe_n),
      .sram_we_n(sram_we_n),
      .sram_ub_n(sram_ub_n),
      .sram_lb_n(sram_lb_n)
  );

  // Sector words, clk_74a -> clk_sys
  reg fifo_clear = 0;
  reg fifo_rd = 0;
  wire [15:0] fifo_q;
  wire fifo_empty;

  msu_fifo #(16, 10) sector_fifo (
      .aclr(fifo_clear),

      .wrclk(clk_74a),
      .wrreq(fifo_wr),
      .data(fifo_wdata),
      .wrfull(),
      .wrusedw(),

      .rdclk(clk_sys),
      .rdreq(fifo_rd),
      .q(fifo_q),
      .rdempty(fifo_empty),
      .rdusedw()
  );

  // ---------------------------------------------------------------------------
  // clk_sys side: the hps_ext.v contract

  reg old_track_request = 0;
  reg old_audio_req = 0;
  reg old_audio_seek = 0;
  reg [9:0] words_left = 0;
  reg [1:0] clear_cnt = 0;
  reg dq_busy = 0;

  always @(posedge clk_sys) begin
    msu_audio_data_wr <= 0;
    fifo_rd <= 0;

    old_track_request <= msu_track_request;
    old_audio_req <= msu_audio_req;
    old_audio_seek <= msu_audio_seek;

    // A few cycles of asynchronous clear
    if (clear_cnt != 0) clear_cnt <= clear_cnt - 1;
    fifo_clear <= clear_cnt != 0;

    // hps_ext: ack follows the download window
    msu_audio_ack <= msu_audio_download;

    if (snes_reset) begin
      msu_track_mounting <= 0;
      msu_track_missing <= 0;
      msu_audio_download <= 0;
      words_left <= 0;
    end else begin
      if (msu_track_request && ~old_track_request) begin
        tr_num <= msu_track_num;
        tr_tgl <= ~tr_tgl;
        msu_track_mounting <= 1;
        msu_track_missing <= 0;
        // Abandon a sector in flight; the FIFO is cleared once the host has
        // mounted the new track and sends nothing more for the old one
        msu_audio_download <= 0;
        words_left <= 0;
      end

      if (track_done_sys) begin
        msu_audio_size <= td_size;
        msu_track_missing <= td_missing;
        msu_track_mounting <= 0;
        clear_cnt <= 2'd3;
      end

      if (~msu_track_request && ((msu_audio_req && ~old_audio_req) ||
                                 (msu_audio_seek && ~old_audio_seek))) begin
        sr_sector <= msu_audio_sector;
        sr_tgl <= ~sr_tgl;
      end

      // One word every other cycle; the host filled all 512 before signalling
      if (sector_ready_sys && ~msu_track_mounting && words_left == 0) begin
        msu_audio_download <= 1;
        words_left <= 10'd512;
      end else if (words_left != 0 && ~msu_audio_data_wr && ~fifo_empty) begin
        msu_audio_data <= fifo_q;
        msu_audio_data_wr <= 1;
        fifo_rd <= 1;
        words_left <= words_left - 1;
      end else if (words_left == 0 && msu_audio_download && ~msu_audio_data_wr) begin
        msu_audio_download <= 0;
      end
    end

    // Data port
    if (msu_ram_req != msu_ram_ack && ~dq_busy) begin
      dq_addr <= msu_ram_addr;
      dq_tgl  <= ~dq_tgl;
      dq_busy <= 1;
    end
    if (data_done_sys) begin
      msu_ram_dout <= dr_data;
      msu_ram_ack  <= msu_ram_req;
      dq_busy <= 0;
    end
  end

  // ---------------------------------------------------------------------------
  // Event log. SNES-side events are collected here, one per cycle.

  wire [7:0] dbg_volume = msu_dbg[7:0];
  wire [2:0] dbg_ctrl = msu_dbg[10:8];  // {resume, repeat, playing}
  wire dbg_end = msu_dbg[11];
  wire dbg_dseek = msu_dbg[12];
  wire dbg_dack = msu_dbg[13];
  wire [23:0] dbg_rom = msu_dbg[39:16];
  wire [23:0] dbg_daddr = msu_dbg[63:40];

  reg ev_valid = 0;
  reg [7:0] ev_type = 0;
  reg [23:0] ev_data = 0;

  reg p_track = 0, p_busy_end = 0, p_ctrl = 0, p_volume = 0, p_end = 0;
  reg p_dseek = 0, p_dready = 0, p_rom = 0, p_reset = 0;
  reg [15:0] c_track = 0;
  reg [2:0] c_ctrl = 0, old_ctrl = 0;
  reg [7:0] c_volume = 0, logged_volume = 0;
  reg [23:0] c_daddr = 0, c_rom = 0;
  reg c_reset = 0;
  reg old_req_ev = 0, old_dseek = 0, old_dack = 0, old_vblank = 0, old_reset = 0;
  reg [2:0] frame = 0;

  always @(posedge clk_sys) begin
    ev_valid <= 0;

    old_req_ev <= msu_track_request;
    old_dseek <= dbg_dseek;
    old_dack <= dbg_dack;
    old_vblank <= snes_vblank;
    old_ctrl <= dbg_ctrl;
    old_reset <= snes_reset;

    if (msu_track_request && ~old_req_ev) begin
      p_track <= 1;
      c_track <= msu_track_num;
    end
    if (~msu_track_request && old_req_ev) p_busy_end <= 1;
    if (dbg_ctrl != old_ctrl) begin
      p_ctrl <= 1;
      c_ctrl <= dbg_ctrl;
    end
    if (dbg_end) p_end <= 1;
    if (dbg_dseek && ~old_dseek) begin
      p_dseek <= 1;
      c_daddr <= dbg_daddr;
    end
    if (dbg_dack && ~old_dack) p_dready <= 1;
    if (snes_reset != old_reset) begin
      p_reset <= 1;
      c_reset <= snes_reset;
    end

    // Per frame: the volume if it changed (every 4th frame), a ROM address
    // sample (every 8th)
    if (snes_vblank && ~old_vblank) begin
      frame <= frame + 1'd1;
      if (frame[1:0] == 0 && dbg_volume != logged_volume) begin
        p_volume <= 1;
        c_volume <= dbg_volume;
        logged_volume <= dbg_volume;
      end
      if (frame == 0) begin
        p_rom <= 1;
        c_rom <= dbg_rom;
      end
    end

    if (~ev_valid) begin
      ev_valid <= 1;
      if (p_reset) begin
        p_reset <= 0;
        ev_type <= EV_S_RESET;
        ev_data <= {23'd0, c_reset};
      end else if (p_track) begin
        p_track <= 0;
        ev_type <= EV_S_TRACK;
        ev_data <= {8'd0, c_track};
      end else if (p_busy_end) begin
        p_busy_end <= 0;
        ev_type <= EV_S_BUSY_END;
        ev_data <= 0;
      end else if (p_ctrl) begin
        p_ctrl <= 0;
        ev_type <= EV_S_CTRL;
        ev_data <= {21'd0, c_ctrl};
      end else if (p_end) begin
        p_end <= 0;
        ev_type <= EV_S_END;
        ev_data <= 0;
      end else if (p_dseek) begin
        p_dseek <= 0;
        ev_type <= EV_S_DSEEK;
        ev_data <= c_daddr;
      end else if (p_dready) begin
        p_dready <= 0;
        ev_type <= EV_S_DREADY;
        ev_data <= 0;
      end else if (p_volume) begin
        p_volume <= 0;
        ev_type <= EV_S_VOLUME;
        ev_data <= {16'd0, c_volume};
      end else if (p_rom) begin
        p_rom <= 0;
        ev_type <= EV_S_ROM;
        ev_data <= c_rom;
      end else begin
        ev_valid <= 0;
      end
    end
  end

  msu_log log (
      .clk(clk_74a),
      .clk_sys(clk_sys),

      .a_valid(evc_valid),
      .a_type (evc_type),
      .a_data (evc_data),

      .b_valid(evs_valid),
      .b_type (evs_type),
      .b_data (evs_data),

      .s_valid(ev_valid),
      .s_type (ev_type),
      .s_data (ev_data),

      .bridge_rd(bridge_rd),
      .bridge_addr(bridge_addr),
      .bridge_endian_little(bridge_endian_little),
      .rd_data(log_rd_data)
  );
endmodule
