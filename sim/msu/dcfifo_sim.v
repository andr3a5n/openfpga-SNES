// Simulation stand-in for Altera's dcfifo, as msu_fifo.v uses it: show-ahead
// output, word counts on both sides, asynchronous clear. Not cycle-accurate
// for the clock crossing: both sides see the pointers immediately.

module dcfifo (
    input wire aclr,
    input wire [lpm_width-1:0] data,
    input wire rdclk,
    input wire rdreq,
    input wire wrclk,
    input wire wrreq,
    output wire [lpm_width-1:0] q,
    output wire rdempty,
    output wire wrfull,
    output wire [lpm_widthu-1:0] wrusedw,
    output wire [lpm_widthu-1:0] rdusedw,
    output wire eccstatus,
    output wire rdfull,
    output wire wrempty
);
  parameter intended_device_family = "Cyclone V";
  parameter lpm_numwords = 16;
  parameter lpm_showahead = "ON";
  parameter lpm_type = "dcfifo";
  parameter lpm_width = 8;
  parameter lpm_widthu = 4;
  parameter overflow_checking = "ON";
  parameter rdsync_delaypipe = 4;
  parameter read_aclr_synch = "OFF";
  parameter underflow_checking = "ON";
  parameter use_eab = "ON";
  parameter write_aclr_synch = "OFF";
  parameter wrsync_delaypipe = 4;
  parameter clocks_are_synchronized = "FALSE";

  reg [lpm_width-1:0] mem[0:lpm_numwords-1];
  integer wr_ptr = 0, rd_ptr = 0;

  wire [31:0] used = wr_ptr - rd_ptr;

  assign q = mem[rd_ptr % lpm_numwords];
  assign rdempty = used == 0;
  assign wrempty = used == 0;
  assign wrfull = used >= lpm_numwords;
  assign rdfull = wrfull;
  assign wrusedw = used[lpm_widthu-1:0];
  assign rdusedw = used[lpm_widthu-1:0];
  assign eccstatus = 1'b0;

  always @(posedge wrclk or posedge aclr) begin
    if (aclr) wr_ptr <= 0;
    else if (wrreq && !wrfull) begin
      mem[wr_ptr%lpm_numwords] <= data;
      wr_ptr <= wr_ptr + 1;
    end
  end

  always @(posedge rdclk or posedge aclr) begin
    if (aclr) rd_ptr <= 0;
    else if (rdreq && !rdempty) rd_ptr <= rd_ptr + 1;
  end
endmodule
