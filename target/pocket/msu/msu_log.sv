// MSU-1 event log: a ring of the last 2048 events with a microsecond
// timestamp, readable over the bridge at 0x5000_0000 as the nonvolatile data
// slot "MSU-1 Log". The Pocket writes it to the SD card when the core is
// quit (Saves/snes/.../<rom>.msulog); tools/msu_log.py decodes it.
//
// File layout, little-endian 32-bit words:
//   0     "MSUL"
//   1     format version (1)
//   2     events written since power-on; the ring holds the last 2048
//   3     events lost because an input was full
//   4..   2048 entries of two words: time in us, {type[7:0], data[23:0]}
//         entry n is event number n mod 2048
//
// Inputs: two event ports in clk (msu_host) and one in clk_sys (the SNES
// side), each at most one event per cycle. Codes are in msu_ev.sv.

module msu_log
  import msu_ev::*;
#(
    parameter int DEPTH_LOG2 = 11
) (
    input wire clk,  // clk_74a
    input wire clk_sys,

    input wire        a_valid,
    input wire [ 7:0] a_type,
    input wire [23:0] a_data,

    input wire        b_valid,
    input wire [ 7:0] b_type,
    input wire [23:0] b_data,

    input wire        s_valid,  // clk_sys
    input wire [ 7:0] s_type,
    input wire [23:0] s_data,

    input  wire        bridge_rd,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_endian_little,
    output reg  [31:0] rd_data = 0
);
  localparam int DEPTH = 1 << DEPTH_LOG2;
  // Bytes in the file, for the datatable
  localparam [31:0] LOG_BYTES = 16 + DEPTH * 8;

  // ---------------------------------------------------------------------------
  // Microseconds: 74.25 cycles each, as 3 x 74 + 1 x 75

  reg [6:0] us_div = 0;
  reg [1:0] us_phase = 0;
  reg [31:0] now_us = 0;

  always @(posedge clk) begin
    us_div <= us_div + 1'd1;
    if (us_div == (us_phase == 2'd3 ? 7'd74 : 7'd73)) begin
      us_div <= 0;
      us_phase <= us_phase + 1'd1;
      now_us <= now_us + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Inputs: small queues, drained one event per cycle

  // clk_sys events cross in a dual-clock FIFO
  wire [31:0] s_q;
  wire s_empty;
  wire s_full;
  reg s_rd = 0;
  reg s_lost_tgl = 0;

  always @(posedge clk_sys) if (s_valid && s_full) s_lost_tgl <= ~s_lost_tgl;

  msu_fifo #(32, 4) s_fifo (
      .aclr(1'b0),

      .wrclk(clk_sys),
      .wrreq(s_valid & ~s_full),
      .data({s_type, s_data}),
      .wrfull(s_full),
      .wrusedw(),

      .rdclk(clk),
      .rdreq(s_rd),
      .q(s_q),
      .rdempty(s_empty),
      .rdusedw()
  );

  reg [2:0] s_lost_s = 0;
  always @(posedge clk) s_lost_s <= {s_lost_s[1:0], s_lost_tgl};

  // clk events: 8-entry queues
  reg [31:0] a_mem[0:7];
  reg [31:0] b_mem[0:7];
  reg [2:0] a_wr = 0, a_rd = 0, b_wr = 0, b_rd = 0;
  reg [3:0] a_cnt = 0, b_cnt = 0;
  reg a_pop = 0, b_pop = 0;

  wire a_push = a_valid && a_cnt != 4'd8;
  wire b_push = b_valid && b_cnt != 4'd8;

  always @(posedge clk) begin
    if (a_push) begin
      a_mem[a_wr] <= {a_type, a_data};
      a_wr <= a_wr + 1'd1;
    end
    if (b_push) begin
      b_mem[b_wr] <= {b_type, b_data};
      b_wr <= b_wr + 1'd1;
    end
    if (a_pop) a_rd <= a_rd + 1'd1;
    if (b_pop) b_rd <= b_rd + 1'd1;
    a_cnt <= a_cnt + a_push - a_pop;
    b_cnt <= b_cnt + b_push - b_pop;
  end

  // ---------------------------------------------------------------------------
  // Writer

  reg [63:0] mem[0:DEPTH-1];
  reg we = 0;
  reg [DEPTH_LOG2-1:0] waddr = 0;
  reg [63:0] wdata = 0;
  reg [DEPTH_LOG2-1:0] raddr = 0;
  reg [63:0] q = 0;

  always @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    q <= mem[raddr];
  end

  reg [31:0] written = 0;
  reg [31:0] lost = 0;
  reg lost_pending = 0;

  task put(input [31:0] ev);
    begin
      we <= 1;
      waddr <= written[DEPTH_LOG2-1:0];
      wdata <= {ev, now_us};
      written <= written + 1;
    end
  endtask

  always @(posedge clk) begin
    we <= 0;
    a_pop <= 0;
    b_pop <= 0;
    s_rd <= 0;

    if ((a_valid && a_cnt == 4'd8) || (b_valid && b_cnt == 4'd8) || (s_lost_s[2] ^ s_lost_s[1]))
    begin
      lost <= lost + 1;
      lost_pending <= 1;
    end

    // One event per two cycles, so the pops and the FIFO settle
    if (~we && ~a_pop && ~b_pop && ~s_rd) begin
      if (a_cnt != 0) begin
        put(a_mem[a_rd]);
        a_pop <= 1;
      end else if (b_cnt != 0) begin
        put(b_mem[b_rd]);
        b_pop <= 1;
      end else if (~s_empty) begin
        put(s_q);
        s_rd <= 1;
      end else if (lost_pending) begin
        put({EV_LOG_LOST, lost[23:0]});
        lost_pending <= 0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Bridge reads at 0x5xxxxxxx. As in the probe, the word for an address is
  // fetched after its read strobe and returned on the following transaction.

  reg [2:0] rd_pipe = 0;
  reg [12:0] rd_word = 0;
  reg [31:0] rd_value = 0;

  always @(posedge clk) begin
    rd_pipe <= {rd_pipe[1:0], 1'b0};

    if (bridge_rd && bridge_addr[31:28] == 4'h5) begin
      rd_word <= bridge_addr[14:2];
      raddr <= (bridge_addr[14:2] - 13'd4) >> 1;
      rd_pipe <= 3'b001;
    end

    if (rd_pipe[1]) begin
      case (rd_word)
        13'd0: rd_value <= "LUSM";  // "MSUL" in file byte order
        13'd1: rd_value <= 32'd1;
        13'd2: rd_value <= written;
        13'd3: rd_value <= lost;
        default: rd_value <= rd_word[0] ? q[63:32] : q[31:0];
      endcase
    end

    if (rd_pipe[2]) begin
      rd_data <= bridge_endian_little ? rd_value :
          {rd_value[7:0], rd_value[15:8], rd_value[23:16], rd_value[31:24]};
    end
  end
endmodule
