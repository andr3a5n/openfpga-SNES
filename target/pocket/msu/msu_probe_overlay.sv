// Text overlay for the MSU-1 probe: 32x28 characters of 8x8 pixels over the
// SNES picture. The probe writes the character RAM from clk_74a.
//
// All video signals are delayed by the same 3 cycles the character and font
// lookups take, so sync and data enable keep their relative timing.

module msu_probe_overlay (
    input wire clk_74a,
    input wire scr_we,
    input wire [9:0] scr_addr,
    input wire [7:0] scr_data,
    input wire enable,  // clk_74a domain

    input wire clk_video,
    input wire hs_in,
    input wire vs_in,
    input wire de_in,
    input wire [23:0] rgb_in,

    output reg hs_out = 0,
    output reg vs_out = 0,
    output reg de_out = 0,
    output reg [23:0] rgb_out = 0
);
  // Character RAM, written from clk_74a, read from clk_video
  reg [7:0] char_mem[0:1023];
  reg [7:0] char_q = 0;

  always @(posedge clk_74a) begin
    if (scr_we) char_mem[scr_addr] <= scr_data;
  end

  reg [1:0] enable_s = 0;
  always @(posedge clk_video) enable_s <= {enable_s[0], enable};

  // Beam position
  reg prev_de = 0;
  reg prev_vs = 0;
  reg [8:0] x = 0;
  reg [8:0] y = 0;

  always @(posedge clk_video) begin
    prev_de <= de_in;
    prev_vs <= vs_in;

    if (de_in) x <= x + 1;
    else x <= 0;

    if (vs_in && ~prev_vs) y <= 0;
    else if (~de_in && prev_de) y <= y + 1;
  end

  // Stage 1: character, stage 2: font row, stage 3: pixel
  reg [2:0] x_d1 = 0, x_d2 = 0;
  reg [2:0] row_d1 = 0;
  reg on_text_d1 = 0, on_text_d2 = 0;

  wire on_text = x < 9'd256 && y < 9'd224;

  always @(posedge clk_video) begin
    char_q <= char_mem[{y[7:3], x[7:3]}];
    x_d1 <= x[2:0];
    row_d1 <= y[2:0];
    on_text_d1 <= on_text;

    x_d2 <= x_d1;
    on_text_d2 <= on_text_d1;
  end

  wire printable = char_q >= 8'h20 && char_q < 8'h7F;
  wire [6:0] glyph = char_q[6:0] - 7'h20;
  wire [7:0] font_q;

  msu_probe_font font (
      .clk (clk_video),
      .addr({glyph, row_d1}),
      .q   (font_q)
  );

  reg printable_d2 = 0;
  always @(posedge clk_video) printable_d2 <= printable;

  wire pixel = printable_d2 && font_q[7-x_d2];

  reg [2:0] hs_d = 0, vs_d = 0, de_d = 0;
  reg [23:0] rgb_d1 = 0, rgb_d2 = 0;

  always @(posedge clk_video) begin
    hs_d <= {hs_d[1:0], hs_in};
    vs_d <= {vs_d[1:0], vs_in};
    de_d <= {de_d[1:0], de_in};
    rgb_d1 <= rgb_in;
    rgb_d2 <= rgb_d1;

    hs_out <= hs_d[1];
    vs_out <= vs_d[1];
    de_out <= de_d[1];

    if (enable_s[1] && on_text_d2) rgb_out <= pixel ? 24'hFFFFFF : 24'h00_00_60;
    else rgb_out <= rgb_d2;
  end
endmodule
