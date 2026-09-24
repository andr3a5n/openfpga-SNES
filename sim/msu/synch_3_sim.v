// Simulation stand-in for synch_3 in platform/pocket/common.v. core_bridge_cmd
// instantiates it with three positional ports, which Icarus rejects against
// the five-port original.

module synch_3 #(
    parameter WIDTH = 1
) (
    input wire [WIDTH-1:0] i,
    output reg [WIDTH-1:0] o,
    input wire clk
);
  reg [WIDTH-1:0] stage_1, stage_2;
  always @(posedge clk) {o, stage_2, stage_1} <= {stage_2, stage_1, i};
endmodule
