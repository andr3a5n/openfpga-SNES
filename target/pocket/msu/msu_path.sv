// Builds an MSU-1 file path for APF command 0x0192 (open file into slot).
//
// Input: the 0x0190 response struct for the ROM's slot, already in the
// datatable at RESP_W. Its first 256 bytes are the ROM's full path,
// NUL-terminated, e.g. "/Assets/snes/common/game.sfc".
// Output: the 0x0192 parameter struct at PARAM_W:
//   bytes 0x000-0x0FF  "<path without extension>.msu" or "<...>-<track>.pcm"
//   word  0x100        flags = 0 (open only, never create or resize)
//   word  0x104        size  = 0
//
// Path bytes are stored big-endian within each datatable word (byte 0 in
// [31:24]); core_bridge_cmd byte-swaps the bridge, so this is how the strings
// written by APF appear on the core side.

module msu_path #(
    parameter [7:0] RESP_W = 8'd64,
    parameter [7:0] PARAM_W = 8'd128,
    // Cycles from setting dt_addr to dt_q being valid, including the
    // registered mux in core_top
    parameter int DT_LATENCY = 4
) (
    input wire clk,
    input wire reset,

    input wire        start,
    input wire        kind_pcm,  // 0: ".msu", 1: "-<track>.pcm"
    input wire [15:0] track,

    output reg       busy = 0,
    output reg       done = 0,    // 1-cycle pulse
    output reg       ok = 0,      // path found and result fits in 255 bytes
    output reg [8:0] length = 0,  // result length without NUL

    output reg [7:0] dt_addr = 0,
    output reg dt_wren = 0,
    output reg [31:0] dt_wdata = 0,
    input wire [31:0] dt_q
);
  localparam [3:0] ST_IDLE = 4'd0;
  localparam [3:0] ST_DIGITS = 4'd1;
  localparam [3:0] ST_SCAN_READ = 4'd2;
  localparam [3:0] ST_SCAN_WAIT = 4'd3;
  localparam [3:0] ST_SCAN_BYTE = 4'd4;
  localparam [3:0] ST_CUT = 4'd5;
  localparam [3:0] ST_WRITE_READ = 4'd6;
  localparam [3:0] ST_WRITE_WAIT = 4'd7;
  localparam [3:0] ST_WRITE_BYTE = 4'd8;
  localparam [3:0] ST_WRITE_WORD = 4'd9;
  localparam [3:0] ST_TAIL = 4'd10;

  reg [3:0] state = ST_IDLE;

  // Suffix: ".msu" or "-65535.pcm" at most
  reg [7:0] sfx[0:10];
  reg [3:0] sfx_len = 0;

  // Decimal conversion by repeated subtraction
  reg [15:0] rem = 0;
  reg [2:0] pow_idx = 0;
  reg [3:0] digit = 0;
  reg digit_started = 0;

  function automatic [15:0] pow10(input [2:0] idx);
    case (idx)
      3'd0: pow10 = 16'd10000;
      3'd1: pow10 = 16'd1000;
      3'd2: pow10 = 16'd100;
      3'd3: pow10 = 16'd10;
      default: pow10 = 16'd1;
    endcase
  endfunction

  reg [6:0] word_idx = 0;
  reg [1:0] byte_idx = 0;
  reg [3:0] wait_cnt = 0;
  reg [31:0] word_hold = 0;
  reg [31:0] word_build = 0;

  // Scan results
  reg nul_found = 0;
  reg [8:0] nul_at = 0;
  reg dot_valid = 0;
  reg [8:0] dot_at = 0;
  reg [8:0] cut = 0;

  wire [8:0] byte_pos = {word_idx[5:0], byte_idx};
  wire [7:0] cur_byte = word_hold[31-8*byte_idx-:8];
  wire [8:0] sfx_pos = byte_pos - cut;

  always @(posedge clk) begin
    done <= 0;
    dt_wren <= 0;

    if (reset) begin
      state <= ST_IDLE;
      busy  <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (start) begin
            busy <= 1;
            ok <= 0;
            nul_found <= 0;
            dot_valid <= 0;
            nul_at <= 0;
            dot_at <= 0;

            if (kind_pcm) begin
              sfx[0] <= "-";
              sfx_len <= 1;
              rem <= track;
              pow_idx <= 0;
              digit <= 0;
              digit_started <= 0;
              state <= ST_DIGITS;
            end else begin
              sfx[0] <= ".";
              sfx[1] <= "m";
              sfx[2] <= "s";
              sfx[3] <= "u";
              sfx_len <= 4;
              word_idx <= 0;
              state <= ST_SCAN_READ;
            end
          end
        end

        ST_DIGITS: begin
          if (rem >= pow10(pow_idx)) begin
            rem   <= rem - pow10(pow_idx);
            digit <= digit + 1;
          end else begin
            // Emit this digit unless it is a leading zero
            if (digit != 0 || digit_started || pow_idx == 3'd4) begin
              sfx[sfx_len] <= "0" + digit;
              sfx_len <= sfx_len + 1;
              digit_started <= 1;
            end

            digit <= 0;

            if (pow_idx == 3'd4) begin
              state <= ST_TAIL;  // append ".pcm"
            end else begin
              pow_idx <= pow_idx + 1;
            end
          end
        end

        ST_TAIL: begin
          sfx[sfx_len] <= ".";
          sfx[sfx_len+1] <= "p";
          sfx[sfx_len+2] <= "c";
          sfx[sfx_len+3] <= "m";
          sfx_len <= sfx_len + 4;
          word_idx <= 0;
          state <= ST_SCAN_READ;
        end

        // Find the NUL terminator and the last '.' after the last '/'
        ST_SCAN_READ: begin
          dt_addr <= RESP_W + word_idx;
          wait_cnt <= 0;
          state <= ST_SCAN_WAIT;
        end

        ST_SCAN_WAIT: begin
          wait_cnt <= wait_cnt + 1;
          if (wait_cnt == DT_LATENCY[3:0]) begin
            word_hold <= dt_q;
            byte_idx <= 0;
            state <= ST_SCAN_BYTE;
          end
        end

        ST_SCAN_BYTE: begin
          if (cur_byte == 8'h00) begin
            nul_found <= 1;
            nul_at <= byte_pos;
            state <= ST_CUT;
          end else begin
            if (cur_byte == "/") dot_valid <= 0;
            else if (cur_byte == ".") begin
              dot_valid <= 1;
              dot_at <= byte_pos;
            end

            byte_idx <= byte_idx + 1;

            if (byte_idx == 2'd3) begin
              if (word_idx == 7'd63) begin
                // No terminator in 256 bytes
                state <= ST_CUT;
              end else begin
                word_idx <= word_idx + 1;
                state <= ST_SCAN_READ;
              end
            end
          end
        end

        ST_CUT: begin
          cut <= dot_valid ? dot_at : nul_at;
          length <= (dot_valid ? dot_at : nul_at) + sfx_len;

          if (~nul_found || nul_at == 0 ||
              ((dot_valid ? dot_at : nul_at) + sfx_len > 9'd255)) begin
            busy <= 0;
            done <= 1;
          end else begin
            ok <= 1;
            word_idx <= 0;
            state <= ST_WRITE_READ;
          end
        end

        // Write the parameter struct: path words, then flags and size
        ST_WRITE_READ: begin
          byte_idx <= 0;
          word_build <= 0;

          if (word_idx >= 7'd64) begin
            dt_addr <= PARAM_W + word_idx;
            dt_wdata <= 0;
            dt_wren <= 1;

            if (word_idx == 7'd65) begin
              busy  <= 0;
              done  <= 1;
              state <= ST_IDLE;
            end else begin
              word_idx <= word_idx + 1;
            end
          end else if ({word_idx[5:0], 2'b00} < cut) begin
            // Part of this word comes from the original path
            dt_addr <= RESP_W + word_idx;
            wait_cnt <= 0;
            state <= ST_WRITE_WAIT;
          end else begin
            word_hold <= 0;
            state <= ST_WRITE_BYTE;
          end
        end

        ST_WRITE_WAIT: begin
          wait_cnt <= wait_cnt + 1;
          if (wait_cnt == DT_LATENCY[3:0]) begin
            word_hold <= dt_q;
            state <= ST_WRITE_BYTE;
          end
        end

        ST_WRITE_BYTE: begin
          if (byte_pos < cut) word_build[31-8*byte_idx-:8] <= cur_byte;
          else if (sfx_pos < sfx_len) word_build[31-8*byte_idx-:8] <= sfx[sfx_pos[3:0]];
          else word_build[31-8*byte_idx-:8] <= 8'h00;

          byte_idx <= byte_idx + 1;
          if (byte_idx == 2'd3) state <= ST_WRITE_WORD;
        end

        ST_WRITE_WORD: begin
          dt_addr <= PARAM_W + word_idx;
          dt_wdata <= word_build;
          dt_wren <= 1;
          word_idx <= word_idx + 1;
          state <= ST_WRITE_READ;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
