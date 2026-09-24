// MSU-1 for the Pocket: file access (msu_host), SRAM (msu_sram) and the clock
// crossing to the SNES side. Towards MAIN_SNES it behaves like hps_ext.v and
// the ARM on MiSTer:
//   * a track request raises track_mounting until the track is open, then
//     reports its size, or track_missing
//   * each audio_req/audio_seek is answered with an audio_download window of
//     512 16-bit words (one 1 KB sector), audio_ack high while it lasts
//   * data file reads use msu_data_store's toggle handshake, served from SRAM

module msu_pocket #(
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
    input wire        bridge_wr,
    input wire [31:0] bridge_addr,
    input wire [31:0] bridge_wr_data,
    input wire        bridge_endian_little,

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
    output reg  [63:0] msu_ram_dout = 0
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
      .data_loaded(data_loaded)
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
endmodule
