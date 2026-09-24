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
//   +dtupdate     model APF updating the datatable size after 0x0192
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

  string dir;
  string log_name;
  bit dtupdate;
  bit clampfail;

  string slot_path[0:63];
  integer slot_size[0:63];
  integer file_slot[0:63];  // slot id -> datatable pair index, -1 if none

  task bridge_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      bridge_addr <= addr;
      bridge_wr_data <= data;
      bridge_wr <= 1;
      @(posedge clk);
      bridge_wr <= 0;
      @(posedge clk);
    end
  endtask

  // One bus transaction: the data is sampled 4 cycles after the address,
  // then the read strobe tells the core to prepare the next word
  task bridge_txn(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      bridge_addr <= addr;
      repeat (4) @(posedge clk);
      data = bridge_rd_data;
      bridge_rd <= 1;
      @(posedge clk);
      bridge_rd <= 0;
      repeat (4) @(posedge clk);
    end
  endtask

  task bridge_read(input [31:0] addr, output [31:0] data);
    reg [31:0] stale;
    begin
      bridge_txn(addr, stale);
      bridge_txn(addr, data);
    end
  endtask

  reg [31:0] path_words[0:63];

  function automatic string words_to_path();
    string s;
    integer i, b;
    reg [7:0] c;
    begin
      s = "";
      for (i = 0; i < 64; i++) begin
        for (b = 0; b < 4; b++) begin
          c = path_words[i][31-8*b-:8];
          if (c == 0) return s;
          s = {s, string'(c)};
        end
      end
      return s;
    end
  endfunction

  // Map an APF path to the test directory
  function automatic string host_path(input string apf_path);
    string prefix;
    begin
      prefix = "/Assets/snes/common/msuprobe/";
      if (apf_path.len() > prefix.len() && apf_path.substr(0, prefix.len() - 1) == prefix)
        return {dir, "/", apf_path.substr(prefix.len(), apf_path.len() - 1)};
      return "";
    end
  endfunction

  function automatic integer file_size(input string path);
    integer fd, size;
    begin
      fd = $fopen(path, "rb");
      if (fd == 0) return -1;
      void'($fseek(fd, 0, 2));
      size = $ftell(fd);
      $fclose(fd);
      return size;
    end
  endfunction

  task finish_cmd(input [2:0] result, input [15:0] cmd);
    begin
      bridge_write(32'hF8001000, {16'h6F6B, 13'b0, result});
    end
  endtask

  task serve(input [15:0] cmd);
    reg [31:0] p0, p1, p2, p3, w;
    string path, host;
    integer fd, i, size, len, c, b, slot;
    reg [31:0] data;
    begin
      bridge_read(32'hF8001020, p0);
      bridge_read(32'hF8001024, p1);
      bridge_read(32'hF8001028, p2);
      bridge_read(32'hF800102C, p3);
      bridge_write(32'hF8001000, {16'h6275, cmd});  // busy
      slot = p0[15:0];

      case (cmd)
        16'h0140: finish_cmd(0, cmd);

        16'h0190: begin
          repeat (2000) @(posedge clk);
          if (slot < 64) path = slot_path[slot];
          else path = "";
          for (i = 0; i < 64; i++) begin
            w = 0;
            for (b = 0; b < 4; b++)
              if (4 * i + b < path.len()) w[31-8*b-:8] = path[4*i+b];
            bridge_write(p1 + 4 * i, w);
          end
          finish_cmd(0, cmd);
          $display("[%0t] APF 0190 slot %0d -> \"%s\"", $time, slot, path);
        end

        16'h0192: begin
          for (i = 0; i < 64; i++) begin
            bridge_read(p1 + 4 * i, w);
            path_words[i] = w;
          end
          bridge_read(p1 + 32'h100, w);
          path = words_to_path();
          host = host_path(path);
          size = host.len() ? file_size(host) : -1;
          repeat (20000) @(posedge clk);
          if (host.len() == 0) begin
            finish_cmd(4, cmd);
            $display("[%0t] APF 0192 slot %0d \"%s\" flags %h -> malformed", $time, slot, path, w);
          end else if (size < 0) begin
            finish_cmd(3, cmd);
            $display("[%0t] APF 0192 slot %0d \"%s\" -> not found", $time, slot, path);
          end else begin
            slot_path[slot] = path;
            slot_size[slot] = size;
            if (dtupdate && file_slot[slot] >= 0)
              bridge_write(32'hF8002000 + 8 * file_slot[slot] + 4, size);
            finish_cmd(0, cmd);
            $display("[%0t] APF 0192 slot %0d \"%s\" -> %0d bytes", $time, slot, path, size);
          end
        end

        16'h0180: begin
          size = slot < 64 && slot_path[slot].len() ? slot_size[slot] : -1;
          len = p3;
          if (size < 0) begin
            finish_cmd(1, cmd);
          end else if (p3 == 32'hFFFF_FFFF && clampfail) begin
            finish_cmd(2, cmd);
          end else if (p1 > size || (p3 != 32'hFFFF_FFFF && p1 + p3 > size)) begin
            finish_cmd(2, cmd);
          end else begin
            if (p3 == 32'hFFFF_FFFF) len = size - p1;
            host = host_path(slot_path[slot]);
            fd = $fopen(host, "rb");
            void'($fseek(fd, p1, 0));
            repeat (500) @(posedge clk);
            for (i = 0; i < len; i += 4) begin
              data = 0;
              for (b = 0; b < 4; b++) begin
                c = $fgetc(fd);
                data[31-8*b-:8] = c < 0 ? 8'h00 : c[7:0];
              end
              bridge_write(p2 + i, data);
            end
            $fclose(fd);
            finish_cmd(0, cmd);
          end
          $display("[%0t] APF 0180 slot %0d offset %0d length %h", $time, slot, p1, p3);
        end

        default: finish_cmd(5, cmd);
      endcase
    end
  endtask

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
    dtupdate  = $test$plusargs("dtupdate");
    clampfail = $test$plusargs("clampfail");

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
