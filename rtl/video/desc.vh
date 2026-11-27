// desc.vh - helpers that pack a 128-bit object descriptor for line_engine.v
// (field layout documented at the top of line_engine.v). Include inside a module.
localparam [2:0] K_IMAGE = 3'd0, K_FILL = 3'd1, K_TILE = 3'd2, K_BLEND = 3'd3;

function [127:0] obj_img;           // picture / sprite, scaled by step (256 = 1:1)
    input signed [10:0] x;
    input signed [9:0]  y;
    input [9:0]  w;
    input [8:0]  h;
    input [7:0]  asset;
    input [18:0] sx0f;
    input [17:0] sy0f;
    input [9:0]  stepx;
    input [9:0]  stepy;
    input        flip;
    obj_img = {1'b0, 1'b0, 4'd0, 12'd0, flip, stepy, stepx, sy0f, sx0f, asset, h, w, y, x, K_IMAGE, 1'b1};
endfunction

function [127:0] obj_fill;          // solid rectangle (dither = 50% checkerboard)
    input signed [10:0] x;
    input signed [9:0]  y;
    input [9:0]  w;
    input [8:0]  h;
    input [11:0] color;
    input        dither;
    obj_fill = {1'b0, dither, 4'd0, color, 1'b0, 10'd256, 10'd256, 18'd0, 19'd0, 8'd0, h, w, y, x, K_FILL, 1'b1};
endfunction

function [127:0] obj_blend;         // tint: out = old*(16-a)/16 + color*a/16
    input signed [10:0] x;
    input signed [9:0]  y;
    input [9:0]  w;
    input [8:0]  h;
    input [11:0] color;
    input [3:0]  alpha;
    obj_blend = {1'b0, 1'b0, alpha, color, 1'b0, 10'd256, 10'd256, 18'd0, 19'd0, 8'd0, h, w, y, x, K_BLEND, 1'b1};
endfunction

function [127:0] obj_tilemap;       // Stage 3 level: first column `col`, then fine scroll sx0f (px, 8 frac bits)
    input signed [9:0]  y;
    input [8:0]  h;
    input [7:0]  level;
    input [7:0]  col;
    input [18:0] sx0f;
    obj_tilemap = {1'b0, 1'b0, 4'd0, 4'd0, col, 1'b0, 10'd256, 10'd256, 18'd0, sx0f, level, h, 10'd640, y, 11'sd0, K_TILE, 1'b1};
endfunction

localparam [127:0] OBJ_NONE = 128'd0;
