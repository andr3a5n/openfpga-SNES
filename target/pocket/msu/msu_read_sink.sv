// Receives the data APF writes for probe reads (command 0x0180) at bridge
// 0x6xxxxxxx. It stores nothing: it counts words and checks them against the
// pattern the test files are generated with, so any read size fits.
//
// Test file pattern, as 32-bit little-endian words: the word at file offset
// `o` (o >= 8) is {tag, o[29:2]}. The first 8 bytes are an MSU-1 header.

module msu_read_sink (
    input wire clk,

    input wire        bridge_wr,
    input wire [31:0] bridge_addr,
    input wire [31:0] bridge_wr_data,
    input wire        bridge_endian_little,

    input wire        arm,         // start of a read: clears `words`
    input wire [31:0] file_base,   // file offset of bridge address 0x6000_0000
    input wire [ 3:0] tag,         // expected pattern tag, 0 = do not check
    input wire        clear_stats,

    output reg [31:0] words = 0,       // words received since `arm`
    output reg [31:0] mismatches = 0,  // since `clear_stats`
    output reg [31:0] first_raw = 0,   // first word ever received, unconverted
    output reg        first_raw_valid = 0,
    output reg [31:0] first_mism_offset = 0,
    output reg [31:0] first_mism_data = 0,
    output reg        first_mism_valid = 0
);
  reg        hit = 0;
  reg [31:0] offset = 0;
  reg [31:0] data = 0;

  wire [31:0] expected = {tag, offset[29:2]};

  always @(posedge clk) begin
    hit <= 0;

    if (bridge_wr && bridge_addr[31:28] == 4'h6) begin
      hit <= 1;
      offset <= file_base + {4'h0, bridge_addr[27:0]};
      // Same conversion as data_loader: file byte 0 ends up in [7:0]
      data <= bridge_endian_little ? bridge_wr_data :
          {bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]};

      if (~first_raw_valid) begin
        first_raw <= bridge_wr_data;
        first_raw_valid <= 1;
      end
    end

    if (arm) words <= 0;
    else if (hit) words <= words + 1;

    if (clear_stats) begin
      mismatches <= 0;
      first_mism_valid <= 0;
      first_raw_valid <= 0;
    end else if (hit && tag != 0 && offset >= 32'd8 && data != expected) begin
      mismatches <= mismatches + 1;

      if (~first_mism_valid) begin
        first_mism_valid <= 1;
        first_mism_offset <= offset;
        first_mism_data <= data;
      end
    end
  end
endmodule
