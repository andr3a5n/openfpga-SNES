// End-to-end MSU-1 test: the unchanged upstream MSU.sv, msu_audio.v and
// msu_data_store.sv, wired as in rtl/mister_top/SNES.sv, served by msu_pocket
// against core_bridge_cmd.v and the firmware model, with an SRAM model.
//
// A CPU model drives the MSU-1 registers like a game: identification, data
// port reads, a missing track, a looping track with a firmware stall, a track
// change during playback, a track that plays once and stops, a replay, and a
// resume. Every sample msu_audio plays is compared with the pattern
// tools/msu_testpack.py wrote.
//
// msu_fader sits between MSU.sv and msu_audio as in MAIN_SNES. A stop or
// track change must never cut msu_audio's output at a volume above zero
// (a click), and busy must clear within 2.5 ms for tracks the boot scan found
// (MiSTer-like), the fade of the old track included. Track 40 lies beyond the
// scan and takes the slow path. At the end the event log is read over the
// bridge like APF does and written to msu_play.msulog.
//
// Two msu_audio behaviours are expected, as on MiSTer: a track that plays
// once stops when msu_audio has fetched its last sector, with up to 767
// samples still in its FIFO, and those play first when the track is played
// again without selecting it anew. A resume restarts at the start of the
// sector that was playing.
//
// msu_audio runs at 10x the real sample rate (clk_rate is set 10x too low),
// which shortens the simulation and puts ten times the real load on the
// streaming path.
//
// Plusargs: +dir=PATH (directory from `msu_testpack.py sim`)
//           +nomsu: no .msu file; MSU-1 must come on from track 1 alone

`timescale 1ns / 1ps

module tb_msu_play;
  reg clk = 0;  // clk_74a; the firmware model expects this name
  always #6.734 clk = ~clk;
  reg clk_sys = 0;
  always #23.28 clk_sys = ~clk_sys;  // 21.477 MHz

  localparam [31:0] CLK_RATE = 32'd2_147_727;  // 10x the real sample rate

  // Test pack, see tools/msu_testpack.py
  localparam integer T1_SAMPLES = 12000;
  localparam integer T1_LOOP = 5000;
  localparam integer T2_SAMPLES = 3000;
  localparam integer T40_SAMPLES = 2000;
  localparam integer DATA_SIZE = 100 * 1024 + 3;

  // ---------------------------------------------------------------------------
  // Bridge and core_bridge_cmd

  reg [31:0] bridge_addr = 0;
  reg bridge_rd = 0;
  reg bridge_wr = 0;
  reg [31:0] bridge_wr_data = 0;
  wire [31:0] bridge_rd_data;
  wire [31:0] cmd_bridge_rd_data;
  wire bridge_endian_little = 0;  // as measured on firmware 2.7

  wire [31:0] log_rd_data;
  assign bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_bridge_rd_data :
      bridge_addr[31:28] == 4'h5 ? log_rd_data : 32'h0;

  wire reset_n;
  wire target_dataslot_read, target_dataslot_getfile, target_dataslot_openfile;
  wire [15:0] target_dataslot_id;
  wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
  wire target_dataslot_done;
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

      .target_dataslot_ack (),
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

  // ---------------------------------------------------------------------------
  // SRAM model: 128K x 16, asynchronous

  wire [16:0] sram_a;
  wire [15:0] sram_dq;
  wire sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;
  reg [15:0] sram[0:131071];

  assign sram_dq = (!sram_oe_n && sram_we_n) ? sram[sram_a] : 16'hZZZZ;
  always @(posedge sram_we_n) sram[sram_a] = sram_dq;

  // ---------------------------------------------------------------------------
  // DUT

  wire dt_own;
  wire [7:0] dt_addr;
  wire dt_wren;
  wire [31:0] dt_wdata;
  wire booted;

  reg snes_reset = 1;

  wire msu_enable;
  wire [15:0] msu_track_num;
  wire msu_track_request;
  wire msu_track_mounting;
  wire msu_track_missing;
  wire [31:0] msu_audio_size;
  wire msu_audio_ack;
  wire msu_audio_req;
  wire msu_audio_seek;
  wire [21:0] msu_audio_sector;
  wire msu_audio_download;
  wire [15:0] msu_audio_data;
  wire msu_audio_data_wr;
  wire [28:0] msu_ram_addr;
  wire msu_ram_req;
  wire msu_ram_ack;
  wire [63:0] msu_ram_dout;
  wire hold_busy;

  // Vertical blank for the event log: every 16.64 ms
  reg vblank = 0;
  always begin
    #16_570_000 vblank = 1;
    #70_000 vblank = 0;
  end

  msu_pocket #(
      .QUEUE_LOG2(5)  // 32 KB, smaller than track 1, so the queue wraps
  ) dut (
      .clk_74a(clk),
      .clk_sys(clk_sys),
      .reset_n(reset_n),
      .snes_reset(snes_reset),

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
      .dt_q    (datatable_q),

      .bridge_wr(bridge_wr),
      .bridge_rd(bridge_rd),
      .bridge_addr(bridge_addr),
      .bridge_wr_data(bridge_wr_data),
      .bridge_endian_little(bridge_endian_little),
      .log_rd_data(log_rd_data),

      .sram_a(sram_a),
      .sram_dq(sram_dq),
      .sram_oe_n(sram_oe_n),
      .sram_we_n(sram_we_n),
      .sram_ub_n(sram_ub_n),
      .sram_lb_n(sram_lb_n),

      .booted(booted),

      .msu_enable(msu_enable),
      .msu_track_num(msu_track_num),
      .msu_track_request(msu_track_request),
      .msu_track_mounting(msu_track_mounting),
      .msu_track_missing(msu_track_missing),
      .msu_audio_size(msu_audio_size),
      .msu_audio_ack(msu_audio_ack),
      .msu_audio_req(msu_audio_req),
      .msu_audio_seek(msu_audio_seek),
      .msu_audio_sector(msu_audio_sector),
      .msu_audio_download(msu_audio_download),
      .msu_audio_data(msu_audio_data),
      .msu_audio_data_wr(msu_audio_data_wr),
      .msu_ram_addr(msu_ram_addr),
      .msu_ram_req(msu_ram_req),
      .msu_ram_ack(msu_ram_ack),
      .msu_ram_dout(msu_ram_dout),

      .msu_dbg({
        msu_data_addr[23:0],
        cpu_addr,
        2'b00,
        msu_data_ack,
        msu_data_seek,
        msu_audio_stop,
        msu_audio_resume,
        msu_audio_repeat,
        msu_audio_playing,
        msu_volume
      }),
      .snes_vblank(vblank)
  );

  // core_top's datatable arbitration: the MSU host, else the save size
  always @(posedge clk) begin
    if (dt_own) begin
      datatable_addr <= {2'b0, dt_addr};
      datatable_wren <= dt_wren;
      datatable_data <= dt_wdata;
    end else begin
      datatable_wren <= 1;
      datatable_addr <= 10'd3;
      datatable_data <= 0;
    end
  end

  // ---------------------------------------------------------------------------
  // The SNES side, as in MAIN_SNES

  reg cpu_rd_n = 1, cpu_wr_n = 1, sysclkf_ce = 0;
  reg [23:0] cpu_addr = 0;
  reg [7:0] cpu_dout = 0;
  wire [7:0] msu_dout;

  wire [7:0] msu_volume;
  wire msu_audio_repeat, msu_audio_playing, msu_audio_stop, msu_audio_resume;
  wire [21:0] msu_resume_sector;
  wire [31:0] msu_audio_loop_index, msu_resume_loop_index;
  wire [31:0] msu_data_addr;
  wire [7:0] msu_data;
  wire msu_data_ack, msu_data_seek, msu_data_req;

  MSU msu (
      .CLK(clk_sys),
      .RST_N(~snes_reset),
      .ENABLE(msu_enable),

      .RD_N(cpu_rd_n),
      .WR_N(cpu_wr_n),
      .SYSCLKF_CE(sysclkf_ce),

      .ADDR(cpu_addr),
      .DIN(cpu_dout),
      .DOUT(msu_dout),
      .MSU_SEL(),

      .track_num(msu_track_num),
      .track_request(msu_track_request),
      .track_mounting(msu_track_mounting | hold_busy),

      .volume(msu_volume),
      .status_track_missing(msu_track_missing),
      .status_audio_repeat(msu_audio_repeat),
      .status_audio_playing(msu_audio_playing),
      .audio_stop(msu_audio_stop),
      .audio_resume(msu_audio_resume),
      .audio_sector(msu_audio_sector),
      .resume_sector(msu_resume_sector),
      .audio_loop_index(msu_audio_loop_index),
      .resume_loop_index(msu_resume_loop_index),

      .data_addr(msu_data_addr),
      .data(msu_data),
      .data_ack(msu_data_ack),
      .data_seek(msu_data_seek),
      .data_req(msu_data_req)
  );

  wire [15:0] msu_l, msu_r;
  wire [7:0] fader_volume;
  wire fader_play, fader_track_processing;

  msu_fader fader (
      .clk  (clk_sys),
      .reset(snes_reset),

      .volume(msu_volume),
      .playing(msu_audio_playing),
      .track_request(msu_track_request),
      .audio_stop(msu_audio_stop),

      .audio_volume(fader_volume),
      .audio_play(fader_play),
      .audio_track_processing(fader_track_processing),
      .hold_busy(hold_busy)
  );

  msu_audio audio (
      .reset(snes_reset),

      .clk(clk_sys),
      .clk_rate(CLK_RATE),

      .ctl_volume(fader_volume),
      .ctl_stop(msu_audio_stop),
      .ctl_play(fader_play),
      .ctl_resume(msu_audio_resume),
      .ctl_repeat(msu_audio_repeat),

      .track_size(msu_audio_size),
      .track_processing(fader_track_processing),

      .audio_download(msu_audio_download),
      .audio_data(msu_audio_data),
      .audio_data_wr(msu_audio_data_wr),

      .audio_ack(msu_audio_ack),
      .audio_sector(msu_audio_sector),
      .audio_req(msu_audio_req),
      .audio_seek(msu_audio_seek),
      .resume_sector(msu_resume_sector),
      .audio_loop_index(msu_audio_loop_index),
      .resume_loop_index(msu_resume_loop_index),

      .audio_l(msu_l),
      .audio_r(msu_r)
  );

  wire [31:3] ram_addr;
  assign msu_ram_addr = ram_addr;

  msu_data_store data_store (
      .clk_sys(clk_sys),
      .base_addr(32'd0),

      .rd_next(msu_data_req),
      .rd_seek(msu_data_seek),
      .rd_seek_done(msu_data_ack),
      .rd_addr(msu_data_addr),

      .ram_addr(ram_addr),
      .ram_req (msu_ram_req),
      .ram_ack (msu_ram_ack),
      .ram_din (msu_ram_dout),

      .rd_dout(msu_data)
  );

  // ---------------------------------------------------------------------------
  // Sample checker: every sample msu_audio takes from its FIFO

  integer exp_track = 0;
  integer exp_index = 0;
  integer exp_samples = 0;
  integer exp_loop = 0;
  bit exp_repeat = 0;
  integer played = 0;
  integer errors = 0;
  integer underruns = 0;
  integer loops_done = 0;
  bit started = 0;
  bit checking = 0;  // off while a track is being selected
  integer clicks = 0;

  function automatic [31:0] pattern(input integer track, input integer k);
    reg [15:0] l, r;
    begin
      l = 2 * k + track;
      r = 3 * k + 16'h100 * track;
      pattern = {r, l};
    end
  endfunction

  always @(posedge clk_sys) begin
    if (audio.sample_ce && audio.playing && checking) begin
      if ({audio.sample_r, audio.sample_l} !== pattern(exp_track, exp_index)) begin
        errors++;
        if (errors <= 10)
          $display("[%0t] SAMPLE MISMATCH track %0d index %0d: got %h expected %h", $time,
                   exp_track, exp_index, {audio.sample_r, audio.sample_l},
                   pattern(exp_track, exp_index));
      end
      played++;
      started = 1;
      exp_index++;
      if (exp_index == exp_samples) begin
        if (exp_repeat) begin
          exp_index = exp_loop;
          loops_done++;
        end
      end
    end else if (audio.sample_ce && audio.ctl_play && audio.fifo_empty && started && checking)
    begin
      underruns++;
    end
  end

  // Clicks: msu_audio's output cut while its volume is above zero. The end of
  // a track without repeat is exempt (upstream behaviour, see msu_fader.sv).
  reg old_play = 0, old_processing = 0;
  reg [3:0] since_stop = 4'hF;
  always @(posedge clk_sys) begin
    old_play <= audio.ctl_play;
    old_processing <= audio.track_processing;
    since_stop <= msu_audio_stop ? 4'd0 : (since_stop == 4'hF ? since_stop : since_stop + 1'd1);
    if ((old_play && ~audio.ctl_play && since_stop > 4) ||
        (~old_processing && audio.track_processing && audio.playing)) begin
      if (audio.ctl_volume != 0) begin
        clicks++;
        $display("[%0t] CLICK: output cut at volume %0d", $time, audio.ctl_volume);
      end
    end
  end

  // +hostdebug: sector requests and queue flushes in msu_host
  bit hostdebug = 0;
  initial hostdebug = $test$plusargs("hostdebug");

  always @(posedge clk) begin
    if (hostdebug && dut.host.sector_req)
      $display("[%0t] sector %0d requested: head %0d count %0d fetch %0d", $time,
               dut.host.sector_num, dut.host.head_sector, dut.host.count, dut.host.fetch_sector);
    if (hostdebug && dut.host.flush)
      $display("[%0t] flush to sector %0d", $time, dut.host.flush_sector);
  end

  // ---------------------------------------------------------------------------
  // CPU model: register accesses no faster than the real CPU

  task cpu_write(input [2:0] reg_n, input [7:0] value);
    begin
      @(posedge clk_sys);
      cpu_addr <= 24'h002000 + reg_n;
      cpu_dout <= value;
      cpu_wr_n <= 0;
      @(posedge clk_sys);
      sysclkf_ce <= 1;
      @(posedge clk_sys);
      sysclkf_ce <= 0;
      cpu_wr_n <= 1;
      repeat (4) @(posedge clk_sys);
    end
  endtask

  task cpu_read(input [2:0] reg_n, output [7:0] value);
    begin
      @(posedge clk_sys);
      cpu_addr <= 24'h002000 + reg_n;
      cpu_rd_n <= 0;
      repeat (3) @(posedge clk_sys);
      value = msu_dout;
      cpu_rd_n <= 1;
      repeat (4) @(posedge clk_sys);
    end
  endtask

  task wait_status_clear(input [7:0] mask, input integer limit);
    reg [7:0] st;
    integer n;
    begin
      n = 0;
      cpu_read(0, st);
      while (st & mask) begin
        repeat (200) @(posedge clk_sys);
        cpu_read(0, st);
        n++;
        if (n > limit) $fatal(1, "Status %h still has %h set", st, mask);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Firmware model

  bit apf_hold = 0;  // stop serving, so the test can use the bridge
  bit apf_idle = 0;

  `include "apf_model.svh"

  initial begin
    reg [31:0] t0;

    icb.hstate = 0;
    icb.tstate = 0;
    icb.host_cmd_start = 0;
    icb.status_setup_done_1 = 0;

    if (!$value$plusargs("dir=%s", dir)) dir = "msutest";
    apf_prefix = "/Assets/snes/common/msutest/";
    dtupdate = 1;
    clampfail = 0;
    apf_word_cycles = 20;
    if ($test$plusargs("nomsu")) apf_hide_ext = ".msu";

    for (int i = 0; i < 64; i++) begin
      slot_path[i] = "";
      slot_size[i] = 0;
      file_slot[i] = -1;
    end
    slot_path[0] = "/Assets/snes/common/msutest/msutest.sfc";
    slot_size[0] = file_size(host_path(slot_path[0]));
    if (slot_size[0] < 0) $fatal(1, "Test pack not found in %s", dir);

    // data.json of the MSU-1 core: Cartridge, Save, MSU-1 Audio, MSU-1 Data
    file_slot[0]  = 0;
    file_slot[10] = 1;
    file_slot[20] = 2;
    file_slot[21] = 3;
    bridge_write(32'hF8002000, 0);
    bridge_write(32'hF8002004, slot_size[0]);

    repeat (1000) @(posedge clk);
    bridge_write(32'hF8000000, 32'h434D0011);  // reset exit

    forever begin
      if (apf_hold) begin
        apf_idle = 1;
        wait (!apf_hold);
        apf_idle = 0;
      end
      bridge_read(32'hF8001000, t0);
      if (t0[31:16] == 16'h636D) serve(t0[15:0]);
      repeat (20) @(posedge clk);
    end
  end

  // ---------------------------------------------------------------------------
  // Test sequence

  task expect_track(input integer track, input integer samples, input integer loop,
                    input bit repeat_on);
    begin
      exp_track = track;
      exp_index = 0;
      exp_samples = samples;
      exp_loop = loop;
      exp_repeat = repeat_on;
      loops_done = 0;
      played = 0;
      started = 0;
      checking = 1;
    end
  endtask

  task wait_stopped;
    reg [7:0] st;
    integer n;
    begin
      n = 0;
      cpu_read(0, st);
      while (st & 8'h10) begin  // playing
        repeat (500) @(posedge clk_sys);
        cpu_read(0, st);
        n++;
        if (n > 20000) $fatal(1, "Track %0d did not stop", exp_track);
      end
    end
  endtask

  // Select a track. fast: the boot scan found it, so busy must be short.
  task mount(input integer track, input bit fast);
    realtime t0, busy;
    begin
      checking = 0;
      cpu_write(4, track[7:0]);
      t0 = $realtime;
      cpu_write(5, track[15:8]);
      wait_status_clear(8'h40, 20000);  // audio busy
      busy = $realtime - t0;
      $display("[%0t] track %0d selected: busy for %0.1f us", $time, track, busy / 1000.0);
      if (fast && busy > 2_500_000) begin
        errors++;
        $display("Busy too long for a track in the table");
      end
    end
  endtask

  string log_name;

  initial begin
    reg [7:0] v, st;
    string id;
    integer fd, i, n;
    reg [7:0] expected;

    // The core holds the SNES in reset until the host has booted
    wait (booted);
    repeat (20) @(posedge clk_sys);
    snes_reset = 0;
    repeat (20) @(posedge clk_sys);
    $display("[%0t] booted, msu_enable = %0d, data file %0d bytes in SRAM", $time, msu_enable,
             dut.data_loaded);
    if (!msu_enable) $fatal(1, "MSU-1 not detected");

    if ($test$plusargs("nomsu")) begin
      // Only track 1: MSU-1 on, the data port reads zeros
      cpu_write(0, 8'h10);
      cpu_write(1, 8'h00);
      cpu_write(2, 8'h00);
      cpu_write(3, 8'h00);
      wait_status_clear(8'h80, 1000);
      for (i = 0; i < 16; i++) begin
        cpu_read(1, v);
        if (v !== 8'h00) errors++;
      end
      if (dut.data_loaded != 0) errors++;
      if (errors == 0) $display("PASS: MSU-1 without a .msu file");
      else $display("FAIL: MSU-1 without a .msu file");
      $finish;
    end

    // Identification
    id = "";
    for (i = 2; i < 8; i++) begin
      cpu_read(i, v);
      id = {id, string'(v)};
    end
    $display("[%0t] ID \"%s\"", $time, id);
    if (id != "S-MSU1") $fatal(1, "Wrong MSU-1 ID");

    // Data port: seek, wait for busy to clear, read
    cpu_write(0, 8'h34);
    cpu_write(1, 8'h12);
    cpu_write(2, 8'h00);
    cpu_write(3, 8'h00);
    wait_status_clear(8'h80, 1000);
    for (i = 0; i < 300; i++) begin
      cpu_read(1, v);
      expected = (((32'h1234 + i) * 7) + ((32'h1234 + i) >> 8)) & 8'hFF;
      if (v !== expected) begin
        errors++;
        if (errors <= 10)
          $display("[%0t] DATA MISMATCH at %h: got %h expected %h", $time, 32'h1234 + i, v,
                   expected);
      end
    end
    $display("[%0t] data port: 300 bytes read from 0x1234", $time);

    // Seek near the end of the data file: the last bytes, then zeros past it
    cpu_write(0, (DATA_SIZE - 4) & 8'hFF);
    cpu_write(1, ((DATA_SIZE - 4) >> 8) & 8'hFF);
    cpu_write(2, ((DATA_SIZE - 4) >> 16) & 8'hFF);
    cpu_write(3, 8'h00);
    wait_status_clear(8'h80, 1000);
    for (i = 0; i < 4; i++) begin
      cpu_read(1, v);
      expected = (((DATA_SIZE - 4 + i) * 7) + ((DATA_SIZE - 4 + i) >> 8)) & 8'hFF;
      if (v !== expected) begin
        errors++;
        $display("[%0t] DATA MISMATCH at %h: got %h expected %h", $time, DATA_SIZE - 4 + i, v,
                 expected);
      end
    end

    // A missing track
    mount(3, 1);
    cpu_read(0, st);
    $display("[%0t] track 3: status %h", $time, st);
    if (!(st & 8'h08)) $fatal(1, "Track 3 should be missing");

    // Track 1, looping, past the end several times
    mount(1, 1);
    expect_track(1, T1_SAMPLES, T1_LOOP, 1);
    cpu_read(0, st);
    if (st & 8'h08) $fatal(1, "Track 1 reported missing");
    cpu_write(6, 8'hFF);
    cpu_write(7, 8'h03);  // play, repeat
    wait (loops_done == 1);
    // 5 ms without data (50 ms at the real rate): the queue covers it
    apf_stall_once = 371_250;
    wait (loops_done == 2);
    $display("[%0t] track 1: %0d samples played, looped twice", $time, played);

    // Change track while playing: track 2 once, no repeat. The checker wraps
    // to 0 for the replay below.
    mount(2, 1);
    expect_track(2, T2_SAMPLES, 0, 1);
    cpu_write(7, 8'h01);  // play
    wait_stopped();
    $display("[%0t] track 2: stopped after %0d samples", $time, played);
    if (played > T2_SAMPLES || played < T2_SAMPLES - 767) begin
      errors++;
      $display("Track 2 should stop within 767 samples of its end");
    end

    // Play track 2 again without selecting it: the rest of the first play,
    // then the track from the start (a seek to sector 0, which is queued
    // after the last sector because of the loop point)
    n = played;
    played = 0;
    cpu_write(7, 8'h01);
    wait_stopped();
    $display("[%0t] track 2 again: %0d samples, %0d of them left from before", $time, played,
             T2_SAMPLES - n);
    if (played > 2 * T2_SAMPLES - n || played < 2 * T2_SAMPLES - n - 767) begin
      errors++;
      $display("Track 2 replay: wrong length");
    end

    // Resume: pause track 1 with resume, select it again, play on from the
    // start of the sector that was playing
    mount(1, 1);
    expect_track(1, T1_SAMPLES, T1_LOOP, 1);
    cpu_write(7, 8'h03);
    wait (played == 6000);
    cpu_write(7, 8'h04);  // stop, keep the position for a resume
    repeat (2000) @(posedge clk_sys);
    mount(1, 1);
    exp_index = msu_resume_sector * 256 - 2;
    played = 0;
    started = 0;
    checking = 1;
    $display("[%0t] track 1 resumes at sector %0d", $time, msu_resume_sector);
    cpu_write(7, 8'h03);
    wait (played == 3000);
    $display("[%0t] track 1: 3000 samples after the resume", $time);

    // Beyond the boot scan: opened before busy clears. Track 41 is missing.
    mount(41, 0);
    cpu_read(0, st);
    if (!(st & 8'h08)) $fatal(1, "Track 41 should be missing");
    mount(40, 0);
    expect_track(40, T40_SAMPLES, 0, 0);
    cpu_write(7, 8'h01);
    wait_stopped();
    $display("[%0t] track 40: %0d samples", $time, played);
    if (played > T40_SAMPLES || played < T40_SAMPLES - 767) begin
      errors++;
      $display("Track 40: wrong length");
    end

    // Stop during playback: faded, no click
    mount(1, 1);
    expect_track(1, T1_SAMPLES, T1_LOOP, 1);
    cpu_write(7, 8'h03);
    wait (played == 2000);
    cpu_write(7, 8'h00);
    repeat (50000) @(posedge clk_sys);

    // Read the event log the way APF saves it
    apf_hold = 1;
    wait (apf_idle);
    begin
      integer lf;
      reg [31:0] w;
      if (!$value$plusargs("log=%s", log_name)) log_name = "msu_play.msulog";
      lf = $fopen(log_name, "wb");
      for (i = 0; i < 4 + 2 * 2048; i++) begin
        bridge_read(32'h5000_0000 + 4 * i, w);
        $fwrite(lf, "%c%c%c%c", w[31:24], w[23:16], w[15:8], w[7:0]);
        if (i == 0 && w != 32'h4D53554C) begin
          errors++;
          $display("Event log: bad magic %h", w);
        end
        if (i == 2) $display("Event log: %0d events", {w[7:0], w[15:8], w[23:16], w[31:24]});
      end
      $fclose(lf);
    end

    $display("underruns: %0d, clicks: %0d, errors: %0d", underruns, clicks, errors);
    if (errors == 0 && underruns == 0 && clicks == 0) $display("PASS: MSU-1 playback");
    else $display("FAIL: MSU-1 playback");
    $finish;
  end

  initial begin
    // Upstream registers without a power-up value
    data_store.ram_req = 0;
    data_store.rd_seek_done = 0;
    #300_000_000;
    $fatal(1, "Timeout");
  end
endmodule
