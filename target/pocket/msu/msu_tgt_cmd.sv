// Issues one APF target command at a time through core_bridge_cmd and waits
// for its genuine completion.
//
// core_bridge_cmd leaves target_dataslot_done high "until next command is
// issued": it only clears it once its state machine reaches
// TARG_ST_DATASLOTOP for the NEW command. Waiting for done to go high straight
// after issuing therefore sees the previous command's completion. This module
// waits for done to be low first, then high. (Same fix as HarpMudd's tgt_cmd.v.)
//
// All signals are in the clk_74a domain, like core_bridge_cmd.

module msu_tgt_cmd #(
    // Give up on a command that APF never answers
    parameter [31:0] TIMEOUT_CYCLES = 32'd742_500_000  // 10 s at 74.25 MHz
) (
    input wire clk,
    input wire reset,

    input wire        start,     // 1-cycle pulse, ignored while busy
    input wire [ 1:0] cmd,       // CMD_READ / CMD_GETFILE / CMD_OPENFILE
    input wire [15:0] slot_id,
    input wire [31:0] offset,
    input wire [31:0] bridge_addr,
    input wire [31:0] length,

    output reg        busy = 0,
    output reg        done = 0,      // 1-cycle pulse on completion or timeout
    output reg [ 2:0] err = 0,       // APF result code; 7 on timeout
    output reg        timeout = 0,   // sticky until the next start
    output reg [31:0] cycles = 0,    // start to completion

    // To core_bridge_cmd
    output reg        target_dataslot_read = 0,
    output reg        target_dataslot_getfile = 0,
    output reg        target_dataslot_openfile = 0,
    output reg [15:0] target_dataslot_id = 0,
    output reg [31:0] target_dataslot_slotoffset = 0,
    output reg [31:0] target_dataslot_bridgeaddr = 0,
    output reg [31:0] target_dataslot_length = 0,

    input wire       target_dataslot_done,
    input wire [2:0] target_dataslot_err
);
  localparam [1:0] CMD_READ = 2'd0;
  localparam [1:0] CMD_GETFILE = 2'd1;
  localparam [1:0] CMD_OPENFILE = 2'd2;

  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_WAIT_LOW = 2'd1;
  localparam [1:0] ST_WAIT_HIGH = 2'd2;

  reg [1:0] state = ST_IDLE;

  always @(posedge clk) begin
    done <= 0;
    target_dataslot_read <= 0;
    target_dataslot_getfile <= 0;
    target_dataslot_openfile <= 0;

    if (busy) cycles <= cycles + 1;

    if (reset) begin
      state <= ST_IDLE;
      busy <= 0;
      timeout <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (start) begin
            // Parameters are sampled by core_bridge_cmd when it picks the
            // command up, so they are held until completion
            target_dataslot_id <= slot_id;
            target_dataslot_slotoffset <= offset;
            target_dataslot_bridgeaddr <= bridge_addr;
            target_dataslot_length <= length;

            case (cmd)
              CMD_GETFILE: target_dataslot_getfile <= 1;
              CMD_OPENFILE: target_dataslot_openfile <= 1;
              default: target_dataslot_read <= 1;
            endcase

            busy <= 1;
            timeout <= 0;
            cycles <= 0;
            state <= ST_WAIT_LOW;
          end
        end

        ST_WAIT_LOW: begin
          if (~target_dataslot_done) state <= ST_WAIT_HIGH;
        end

        ST_WAIT_HIGH: begin
          if (target_dataslot_done) begin
            err <= target_dataslot_err;
            busy <= 0;
            done <= 1;
            state <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase

      if (busy && cycles >= TIMEOUT_CYCLES) begin
        err <= 3'd7;
        timeout <= 1;
        busy <= 0;
        done <= 1;
        state <= ST_IDLE;
      end
    end
  end
endmodule
