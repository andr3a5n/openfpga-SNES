// Click-free MSU-1 transitions, between MSU.sv and msu_audio.v (clk_sys).
//
// Upstream, msu_audio's output drops to zero the moment the game stops a
// track or selects another one (its FIFO is cleared), which is a step in the
// waveform: a click. Here:
//   * stop, pause and track change: msu_audio keeps playing while its volume
//     ramps to zero, and only then stops or has its FIFO cleared. For a track
//     change the audio-busy bit stays set until then (hold_busy).
//   * start: the volume ramps up from zero.
//   * volume writes ($2006): the volume moves one step per tick towards the
//     new value instead of jumping.
// A ramp over the full range takes 255 ticks: 1.5 ms at 128 cycles a tick.
// A track that ends by itself (no repeat) stops at once, as upstream: the
// state machine in msu_audio needs play to drop then.

module msu_fader #(
    parameter int TICK_CYCLES = 128
) (
    input wire clk,
    input wire reset,

    // From MSU.sv
    input wire [7:0] volume,
    input wire       playing,
    input wire       track_request,

    // From msu_audio.v: a track without repeat has ended
    input wire audio_stop,

    // To msu_audio.v
    output reg  [7:0] audio_volume = 0,
    output wire       audio_play,
    output wire       audio_track_processing,

    // To MSU.sv, ORed into track_mounting
    output wire hold_busy
);
  reg [7:0] tick_cnt = 0;
  wire tick = tick_cnt == 0;

  always @(posedge clk) tick_cnt <= tick_cnt == TICK_CYCLES - 1 ? 8'd0 : tick_cnt + 1'd1;

  // msu_audio keeps playing while the volume ramps down
  reg hold = 0;
  wire [7:0] target = playing && ~track_request ? volume : 8'd0;

  always @(posedge clk) begin
    if (reset) begin
      audio_volume <= 0;
      hold <= 0;
    end else begin
      if (tick) begin
        if (audio_volume < target) audio_volume <= audio_volume + 1'd1;
        else if (audio_volume > target) audio_volume <= audio_volume - 1'd1;
      end

      if (audio_stop) hold <= 0;
      else if (playing && ~track_request) hold <= 1;
      else if (audio_volume == 0) hold <= 0;
    end
  end

  assign audio_play = playing | hold;
  assign audio_track_processing = track_request & ~hold;
  assign hold_busy = track_request & hold;
endmodule
