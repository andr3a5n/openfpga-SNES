// Behavioural model of the Pocket firmware (APF) side of the bridge, for
// testbenches that instantiate core_bridge_cmd. Include it inside the
// testbench module; it expects clk, bridge_addr, bridge_wr, bridge_wr_data,
// bridge_rd and bridge_rd_data there.
//
// It answers target commands 0x0140, 0x0190, 0x0192 and 0x0180 from files in
// `dir`, standing in for the SD card folder `apf_prefix`. Bridge reads follow
// io_bridge_peripheral.v: the word sent for a transaction is whatever the
// core presented before that transaction's read strobe, so every read is
// issued twice.

  string dir;         // host directory standing in for apf_prefix
  string apf_prefix;  // e.g. "/Assets/snes/common/msuprobe/"
  bit dtupdate;       // write {id, size} to the datatable after 0x0192, as fw 2.7 does
  bit clampfail;      // fail reads with length 0xFFFFFFFF
  integer apf_open_delay = 20000;  // cycles before answering 0x0192
  integer apf_read_delay = 500;    // cycles before the data of a 0x0180
  integer apf_word_cycles = 3;     // cycles per bridge word written by a 0x0180;
                                   // the real bridge needs 16 or more
  integer apf_stall_once = 0;      // extra cycles before the next 0x0180 only
  string apf_hide_ext = "";        // files with this extension are not found

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
  function automatic string host_path(input string path);
    begin
      if (path.len() > apf_prefix.len() && path.substr(0, apf_prefix.len() - 1) == apf_prefix)
        return {dir, "/", path.substr(apf_prefix.len(), path.len() - 1)};
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
          if (apf_hide_ext.len() && path.len() > apf_hide_ext.len() &&
              path.substr(path.len() - apf_hide_ext.len(), path.len() - 1) == apf_hide_ext)
            size = -1;
          repeat (apf_open_delay) @(posedge clk);
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
          end else if (p1 >= size || (p3 != 32'hFFFF_FFFF && p1 + p3 > size)) begin
            // Firmware 2.7: also an error when a clamped read starts at the end
            finish_cmd(2, cmd);
          end else begin
            if (p3 == 32'hFFFF_FFFF) len = size - p1;
            host = host_path(slot_path[slot]);
            fd = $fopen(host, "rb");
            void'($fseek(fd, p1, 0));
            repeat (apf_read_delay) @(posedge clk);
            if (apf_stall_once > 0) begin
              $display("[%0t] APF stalls for %0d cycles", $time, apf_stall_once);
              repeat (apf_stall_once) @(posedge clk);
              apf_stall_once = 0;
            end
            for (i = 0; i < len; i += 4) begin
              data = 0;
              for (b = 0; b < 4; b++) begin
                c = $fgetc(fd);
                data[31-8*b-:8] = c < 0 ? 8'h00 : c[7:0];
              end
              bridge_write(p2 + i, data);
              if (apf_word_cycles > 3) repeat (apf_word_cycles - 3) @(posedge clk);
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
