// sprite_anim.v - FEATURE 1/2: walk animation and facing direction of the player.
// Port of player_sprite.py (Stage 1, MODE=1) and stage2_demo.PlayerSprite (MODE=2).
//   direction: right/left wins when both axes are pressed, else front (down) / back (up)
//   MODE 1 walk cycle: stepl, stand, stepr, stand   (starts with the LEFT leg, t = 0)
//   MODE 2 walk cycle: stand, stepl, stand, stepr   (t starts at dt on the first frame)
//   one frame of the cycle lasts 0.14 s = 8.4 video frames. Counting m = 5*n mod 168
//   gives frame index floor(n / 8.4) mod 4 = m / 42 exactly, with no division.
// dir: 0 front, 1 back, 2 left, 3 right      pose: 0 stand, 1 stepl, 2 stepr
`timescale 1ns / 1ps
module sprite_anim #(parameter MODE = 1) (
    input  wire       clk,
    input  wire       rst,
    input  wire       reset_dir,          // sprite.reset(): face front, stop
    input  wire       upd,                // one frame update
    input  wire       stop,               // sprite.stop() this frame (instead of upd)
    input  wire signed [1:0] dx,          // -1, 0, +1 (input direction)
    input  wire signed [1:0] dy,
    input  wire       moved,              // the position really changed this frame
    output reg  [1:0] dir,
    output wire [1:0] pose
);
    reg       moving;
    reg [7:0] m;                          // 5*n mod 168
    wire [1:0] idx = (m < 8'd42) ? 2'd0 : (m < 8'd84) ? 2'd1 : (m < 8'd126) ? 2'd2 : 2'd3;
    assign pose = !moving ? 2'd0 :
                  (MODE == 1) ? ((idx == 2'd0) ? 2'd1 : (idx == 2'd2) ? 2'd2 : 2'd0)
                              : ((idx == 2'd1) ? 2'd1 : (idx == 2'd3) ? 2'd2 : 2'd0);
    wire [7:0] m5 = (m + 8'd5 >= 8'd168) ? m + 8'd5 - 8'd168 : m + 8'd5;
    always @(posedge clk) begin
        if (rst || reset_dir) begin
            dir <= 2'd0; moving <= 1'b0; m <= 8'd0;
        end else if (stop) begin
            moving <= 1'b0; m <= 8'd0;
        end else if (upd) begin
            if (dx != 0)      dir <= (dx > 0) ? 2'd3 : 2'd2;
            else if (dy != 0) dir <= (dy > 0) ? 2'd0 : 2'd1;
            if (MODE == 1) begin
                if (moved) begin
                    if (moving) m <= m5;
                    else begin moving <= 1'b1; m <= 8'd0; end
                end else begin moving <= 1'b0; m <= 8'd0; end
            end else begin
                moving <= moved;
                m <= moved ? m5 : 8'd0;
            end
        end
    end
endmodule
