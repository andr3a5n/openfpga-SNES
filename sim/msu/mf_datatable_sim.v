// Simulation stand-in for platform/pocket/mf_datatable.v (altsyncram, 256 x 32,
// registered addresses and outputs on both ports)

module mf_datatable (
    input wire [7:0] address_a,
    input wire [7:0] address_b,
    input wire clock_a,
    input wire clock_b,
    input wire [31:0] data_a,
    input wire [31:0] data_b,
    input wire wren_a,
    input wire wren_b,
    output reg [31:0] q_a,
    output reg [31:0] q_b
);
  reg [31:0] mem[0:255];
  reg [7:0] addr_a_r, addr_b_r;

  integer i;
  initial for (i = 0; i < 256; i = i + 1) mem[i] = 0;

  always @(posedge clock_a) begin
    addr_a_r <= address_a;
    if (wren_a) mem[address_a] <= data_a;
    q_a <= mem[addr_a_r];
  end

  always @(posedge clock_b) begin
    addr_b_r <= address_b;
    if (wren_b) mem[address_b] <= data_b;
    q_b <= mem[addr_b_r];
  end
endmodule
