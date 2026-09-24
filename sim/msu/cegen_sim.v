// Simulation stand-in for rtl/upstream/CEGen.vhd: a CE pulse at OUT_CLK/IN_CLK
// of the clock rate, on the falling edge like the original.

module CEGen (
    input wire CLK,
    input wire RST_N,
    input wire [31:0] IN_CLK,
    input wire [31:0] OUT_CLK,
    output reg CE
);
  reg [31:0] sum;

  always @(negedge CLK or negedge RST_N) begin
    if (!RST_N) begin
      sum <= 0;
      CE  <= 0;
    end else begin
      CE <= 0;
      if (sum + OUT_CLK >= IN_CLK) begin
        sum <= sum + OUT_CLK - IN_CLK;
        CE  <= 1;
      end else begin
        sum <= sum + OUT_CLK;
      end
    end
  end
endmodule
