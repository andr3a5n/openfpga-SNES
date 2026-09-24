// Testbench for the MSU-1 phase 0 probe.
//
// Runs msu_probe against the real core_bridge_cmd.v and a behavioural model of
// the Pocket firmware (APF) that answers target commands 0x0140, 0x0190,
// 0x0192 and 0x0180 from files on disk. Bridge reads follow
// io_bridge_peripheral.v: the word sent for a transaction is whatever the core
// presented before that transaction's read strobe, so every read is issued
// twice.
//
// Plusargs:
//   +dir=PATH     directory holding the msuprobe test set
//   +log=FILE     where to write the probe log read back over the bridge
//   +nodtupdate   model APF not updating the datatable size after 0x0192
//                 (firmware 2.7 does update it)
//   +clampfail    model APF failing reads with length 0xFFFFFFFF

`timescale 1ns / 1ps

module tb_msu_probe;
  reg clk = 0;
  always #6.734 clk = ~clk;  // 74.25 MHz

  // ---------------------------------------------------------------------------
  // Bridge

  reg [31:0] bridge_addr = 0;
  reg bridge_rd = 0;
  reg bridge_wr = 0;
  reg [31:0] bridge_wr_data = 0;
  wire [31:0] bridge_rd_data;
  wire [31:0] cmd_bridge_rd_data;
  wire [31:0] log_rd_data;

  // Model a big-endian bridge: no byte swapping in the core
  wire bridge_endian_little = 0;

  assign bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_bridge_rd_data :
      bridge_addr[31:28] == 4'h5 ? log_rd_data : 32'h0;

  // ---------------------------------------------------------------------------
  // DUT: core_bridge_cmd + probe + the core_top datatable mux

  wire reset_n;

  wire target_dataslot_read, target_dataslot_getfile, target_dataslot_openfile;
  wire [15:0] target_dataslot_id;
  wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
  wire target_dataslot_ack, target_dataslot_done;
  wire [2:0] target_dataslot_err;

  reg [9:0] datatable_addr = 0;
  reg datatable_wren = 0;
  reg [31:0] datatable_data = 0;
  wire [31:0] datatable_q;

  core_bridge_cmd icb (
      .clk(clk),
      .reset_n(reset_n),

      .bridge_endian_little(bridge_endian_little),
      .bridge_addr(bridge_addr),
      .bridge_rd(bridge_rd),
      .bridge_rd_data(cmd_bridge_rd_data),
      .bridge_wr(bridge_wr),
      .bridge_wr_data(bridge_wr_data),

      .status_boot_done (1'b1),
      .status_setup_done(1'b1),
      .status_running   (reset_n),

      .dataslot_requestread_ack(1'b1),
      .dataslot_requestread_ok(1'b1),
      .dataslot_requestwrite_ack(1'b1),
      .dataslot_requestwrite_ok(1'b1),

      .savestate_supported(1'b0),
      .savestate_addr(32'h0),
      .savestate_size(32'h0),
      .savestate_maxloadsize(32'h0),
      .savestate_start_ack(1'b0),
      .savestate_start_busy(1'b0),
      .savestate_start_ok(1'b0),
      .savestate_start_err(1'b0),
      .savestate_load_ack(1'b0),
      .savestate_load_busy(1'b0),
      .savestate_load_ok(1'b0),
      .savestate_load_err(1'b0),

      .target_dataslot_read(target_dataslot_read),
      .target_dataslot_write(1'b0),
      .target_dataslot_getfile(target_dataslot_getfile),
      .target_dataslot_openfile(target_dataslot_openfile),

      .target_dataslot_ack (target_dataslot_ack),
      .target_dataslot_done(target_dataslot_done),
      .target_dataslot_err (target_dataslot_err),

      .target_dataslot_id(target_dataslot_id),
      .target_dataslot_slotoffset(target_dataslot_slotoffset),
      .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
      .target_dataslot_length(target_dataslot_length),

      .target_buffer_param_struct(32'hF8002200),
      .target_buffer_resp_struct (32'hF8002100),

      .datatable_addr(datatable_addr),
      .datatable_wren(datatable_wren),
      .datatable_data(datatable_data),
      .datatable_q   (datatable_q)
  );

  wire probe_dt_own;
  wire [7:0] probe_dt_addr;
  wire probe_dt_wren;
  wire [31:0] probe_dt_wdata;

  wire scr_we;
  wire [9:0] scr_addr;
  wire [7:0] scr_data;

  reg button_start = 0;
  wire released, overlay_en;

  msu_probe probe (
      .clk(clk),
      .pll_core_locked(1'b1),
      .reset_n(reset_n),
      .bridge_endian_little(bridge_endian_little),

      .target_dataslot_read(target_dataslot_read),
      .target_dataslot_getfile(target_dataslot_getfile),
      .target_dataslot_openfile(target_dataslot_openfile),
      .target_dataslot_id(target_dataslot_id),
      .target_dataslot_slotoffset(target_dataslot_slotoffset),
      .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
      .target_dataslot_length(target_dataslot_length),
      .target_dataslot_done(target_dataslot_done),
      .target_dataslot_err(target_dataslot_err),

      .dt_own(probe_dt_own),
      .dt_addr(probe_dt_addr),
      .dt_wren(probe_dt_wren),
      .dt_wdata(probe_dt_wdata),
      .dt_q(datatable_q),

      .bridge_addr(bridge_addr),
      .bridge_wr(bridge_wr),
      .bridge_wr_data(bridge_wr_data),
      .bridge_rd(bridge_rd),
      .log_rd_data(log_rd_data),

      .scr_we  (scr_we),
      .scr_addr(scr_addr),
      .scr_data(scr_data),

      .button_start(button_start),
      .released(released),
      .overlay_en(overlay_en)
  );

  // Same arbitration as core_top: the probe, else the nonvolatile slot sizes
  reg size_toggle = 0;
  always @(posedge clk) begin
    size_toggle <= ~size_toggle;
    if (probe_dt_own) begin
      datatable_addr <= {2'b0, probe_dt_addr};
      datatable_wren <= probe_dt_wren;
      datatable_data <= probe_dt_wdata;
    end else begin
      datatable_wren <= 1;
      datatable_addr <= size_toggle ? 10'd5 : 10'd3;
      datatable_data <= size_toggle ? 32'd4096 : 32'd0;
    end
  end

  // Screen copy for the text dump at the end
  reg [7:0] screen[0:1023];
  always @(posedge clk) if (scr_we) screen[scr_addr] <= scr_data;

  // ---------------------------------------------------------------------------
  // APF model

  `include "apf_model.svh"

  string log_name;

  // ---------------------------------------------------------------------------
  // Test sequence

  integer i, fd, cycles;
  reg [31:0] t0, w;

  initial begin
    // core_bridge_cmd leaves its state machines to power up at 0, as FPGA
    // registers do; simulation starts them at X
    icb.hstate = 0;
    icb.tstate = 0;
    icb.host_cmd_start = 0;
    icb.status_setup_done_1 = 0;

    if (!$value$plusargs("dir=%s", dir)) dir = "msuprobe";
    if (!$value$plusargs("log=%s", log_name)) log_name = "msuprobe.msulog";
    dtupdate  = !$test$plusargs("nodtupdate");
    clampfail = $test$plusargs("clampfail");
    apf_prefix = "/Assets/snes/common/msuprobe/";

    for (i = 0; i < 64; i++) begin
      slot_path[i] = "";
      slot_size[i] = 0;
      file_slot[i] = -1;
    end
    slot_path[0] = "/Assets/snes/common/msuprobe/msuprobe.sfc";
    slot_size[0] = file_size(host_path(slot_path[0]));
    if (slot_size[0] < 0) $fatal(1, "Test set not found in %s", dir);

    // APF's {slot id, size} table, in data.json order
    file_slot[0]  = 0;
    file_slot[10] = 1;
    file_slot[30] = 2;
    file_slot[20] = 3;
    file_slot[21] = 4;
    file_slot[22] = 5;
    bridge_write(32'hF8002000, 0);
    bridge_write(32'hF8002004, slot_size[0]);
    bridge_write(32'hF8002008, 10);
    bridge_write(32'hF800200C, 0);
    bridge_write(32'hF8002010, 30);
    bridge_write(32'hF8002014, 0);
    bridge_write(32'hF8002018, 20);
    bridge_write(32'hF800201C, 0);
    bridge_write(32'hF8002020, 21);
    bridge_write(32'hF8002024, 0);
    bridge_write(32'hF8002028, 22);
    bridge_write(32'hF800202C, 0);

    repeat (1000) @(posedge clk);
    bridge_write(32'hF8000000, 32'h434D0011);  // reset exit

    cycles = 0;
    while (probe.state != probe.S_DONE) begin
      bridge_read(32'hF8001000, t0);
      if (t0[31:16] == 16'h636D) serve(t0[15:0]);
      repeat (20) @(posedge clk);
      cycles += 40;
      if (cycles > 200_000_000) $fatal(1, "Probe did not finish");
    end

    if (released) $fatal(1, "SNES released before START");

    // Read the log back the way APF unloads a nonvolatile slot
    fd = $fopen(log_name, "wb");
    for (i = 0; i < 1024; i++) begin
      bridge_read(32'h5000_0000 + 4 * i, w);
      $fwrite(fd, "%c%c%c%c", w[31:24], w[23:16], w[15:8], w[7:0]);
    end
    $fclose(fd);

    // Screen
    for (i = 0; i < 28; i++) begin
      string line;
      integer x;
      line = "";
      for (x = 0; x < 32; x++) line = {line, string'(screen[i*32+x])};
      $display("|%s|", line);
    end

    button_start = 1;
    repeat (10) @(posedge clk);
    if (!released || overlay_en) $fatal(1, "START did not release the SNES");

    $display("PASS: probe finished, log in %s", log_name);
    $finish;
  end
endmodule
