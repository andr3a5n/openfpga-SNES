// Controller for the Pocket's 256 KB asynchronous SRAM (128K x 16), used as
// the MSU-1 audio sector queue and data file store. Three clients, in priority
// order:
//   1. bridge writes to 0x3xxxxxxx: the data of APF 0x0180 reads, which cannot
//      be held off
//   2. 64-bit reads for the MSU-1 data port
//   3. 16-bit reads for serving audio sectors
//
// Timing at 74.25 MHz (13.5 ns): reads sample 3 cycles after the address,
// writes hold WE low for 2 cycles with address and data stable a cycle before
// and after it. A bridge word (two SRAM words) takes 9 cycles; the bridge
// delivers at most one every 16 or so (8 bytes over the SPI link, each
// synchronised into clk_74a), and reads never take longer than 17 cycles, so
// the 4-entry queue does not overflow.

module msu_sram (
    input wire clk,

    // Bridge writes, file byte order: the first file byte of each 32-bit
    // bridge word is bits 31-24 when bridge_endian_little is 0
    input wire        bridge_wr,
    input wire [31:0] bridge_addr,
    input wire [31:0] bridge_wr_data,
    input wire        bridge_endian_little,

    // 64-bit read of 4 words starting at data_addr
    input  wire        data_rd,     // pulse, while ~data_busy
    input  wire [16:0] data_addr,
    output reg         data_busy = 0,
    output reg         data_done = 0,  // pulse
    output reg  [63:0] data_q = 0,

    // 16-bit read
    input  wire        host_rd,     // pulse, while ~host_busy
    input  wire [16:0] host_addr,
    output reg         host_busy = 0,
    output reg         host_done = 0,  // pulse
    output reg  [15:0] host_q = 0,

    // SRAM
    output reg  [16:0] sram_a = 0,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n = 1,
    output reg         sram_we_n = 1,
    output wire        sram_ub_n,
    output wire        sram_lb_n
);
  assign sram_ub_n = 0;
  assign sram_lb_n = 0;

  reg drive = 0;
  reg [15:0] dout = 0;
  assign sram_dq = drive ? dout : 16'hZZZZ;

  // ---------------------------------------------------------------------------
  // Bridge write queue. Each 32-bit bridge word becomes two 16-bit words,
  // little-endian like the file: word 0 = {byte 1, byte 0}.

  reg [16:0] wq_addr[0:3];
  reg [31:0] wq_data[0:3];
  reg [1:0] wq_rd = 0, wq_wr = 0;
  reg [2:0] wq_count = 0;

  wire [31:0] le_data = bridge_endian_little ? bridge_wr_data :
      {bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]};

  wire wq_push = bridge_wr && bridge_addr[31:28] == 4'h3;
  reg wq_pop = 0;

  always @(posedge clk) begin
    // synthesis translate_off
    if (wq_push && wq_count == 3'd4 && ~wq_pop) $error("msu_sram: bridge write queue overflow");
    // synthesis translate_on
    if (wq_push) begin
      wq_addr[wq_wr] <= bridge_addr[17:1];
      wq_data[wq_wr] <= le_data;
      wq_wr <= wq_wr + 1;
    end
    if (wq_pop) wq_rd <= wq_rd + 1;
    wq_count <= wq_count + wq_push - wq_pop;
  end

  // ---------------------------------------------------------------------------
  // SRAM sequencer

  localparam [3:0] ST_IDLE = 0;
  localparam [3:0] ST_WRITE = 1;
  localparam [3:0] ST_READ = 2;

  reg [3:0] state = ST_IDLE;
  reg [2:0] phase = 0;
  reg [1:0] word = 0;  // word within a queued write (0-1) or a data read (0-3)
  reg is_data = 0;
  reg [16:0] base = 0;
  reg [31:0] wdata = 0;

  reg data_pending = 0;
  reg [16:0] data_pending_addr = 0;
  reg host_pending = 0;
  reg [16:0] host_pending_addr = 0;

  always @(posedge clk) begin
    wq_pop <= 0;
    data_done <= 0;
    host_done <= 0;

    if (data_rd && ~data_busy) begin
      data_pending <= 1;
      data_pending_addr <= data_addr;
      data_busy <= 1;
    end
    if (host_rd && ~host_busy) begin
      host_pending <= 1;
      host_pending_addr <= host_addr;
      host_busy <= 1;
    end

    case (state)
      ST_IDLE: begin
        drive <= 0;
        sram_we_n <= 1;
        sram_oe_n <= 1;
        phase <= 0;
        word <= 0;

        if (wq_count != 0 && ~wq_pop) begin
          base <= wq_addr[wq_rd];
          wdata <= wq_data[wq_rd];
          wq_pop <= 1;
          state <= ST_WRITE;
        end else if (data_pending) begin
          data_pending <= 0;
          base <= data_pending_addr;
          is_data <= 1;
          state <= ST_READ;
        end else if (host_pending) begin
          host_pending <= 0;
          base <= host_pending_addr;
          is_data <= 0;
          state <= ST_READ;
        end
      end

      // phase 0: address and data, 1-2: WE low, 3: WE high; address and
      // data change only in the next word's phase 0
      ST_WRITE: begin
        phase <= phase + 1;
        case (phase)
          3'd0: begin
            sram_a <= base + word;
            dout <= word[0] ? wdata[31:16] : wdata[15:0];
            drive <= 1;
          end
          3'd1: sram_we_n <= 0;
          3'd3: begin
            sram_we_n <= 1;
            phase <= 0;
            if (word == 2'd1) state <= ST_IDLE;
            else word <= word + 1;
          end
          default: ;
        endcase
      end

      // phase 0: address and OE, sample in phase 3
      ST_READ: begin
        phase <= phase + 1;
        case (phase)
          3'd0: begin
            sram_a <= base + word;
            sram_oe_n <= 0;
          end
          3'd3: begin
            phase <= 0;
            if (is_data) begin
              data_q[16*word+:16] <= sram_dq;
              if (word == 2'd3) begin
                data_done <= 1;
                data_busy <= 0;
                sram_oe_n <= 1;
                state <= ST_IDLE;
              end else begin
                word <= word + 1;
              end
            end else begin
              host_q <= sram_dq;
              host_done <= 1;
              host_busy <= 0;
              sram_oe_n <= 1;
              state <= ST_IDLE;
            end
          end
          default: ;
        endcase
      end

      default: state <= ST_IDLE;
    endcase
  end
endmodule
