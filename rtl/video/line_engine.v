// line_engine.v - draws ONE line of the 640x360 game view into a line buffer.
//
// HOW IT WORKS (beginner summary)
//   The game view is described every frame as a list of up to 32 "objects" (background
//   picture, player sprite, cards, dim overlay, Stage 3 tile map ...). While the monitor
//   shows line N, this engine walks the object list in order (back to front) and paints
//   line N+1 into the other half of a double line buffer. Each object pixel goes through
//   a 10-stage pipeline (1 pixel per clock, 100 MHz):
//       source position -> tile map ROM -> tile directory -> P4 / VQ index ROM
//       -> VQ code book ROM -> palette ROM -> line buffer write (skipped if transparent)
//   A line has 3200 clocks; a full-width background costs 640, so there is time for
//   several layers plus sprites.
//
// OBJECT DESCRIPTOR (128 bits, produced by the scene module of the active stage)
//   [0]       en
//   [3:1]     kind      0 IMAGE (asset), 1 FILL (solid colour), 2 TILEMAP (Stage 3), 3 BLEND
//   [14:4]    x         signed destination left   (view pixels)
//   [24:15]   y         signed destination top
//   [34:25]   w         destination width
//   [43:35]   h         destination height
//   [51:44]   asset     asset id (IMAGE) or level number (TILEMAP)
//   (TILEMAP only: colour[7:0] = first map column, sx0f = fine scroll 0..31 px)
//   [70:52]   sx0f      source x of the left edge, unsigned 11.8 fixed point
//   [88:71]   sy0f      source y of the top edge,  unsigned 10.8 fixed point
//   [98:89]   stepx     source pixels per destination pixel, 2.8 fixed (256 = 1:1, 128 = 2x zoom)
//   [108:99]  stepy
//   [109]     flipx     mirror horizontally
//   [121:110] color     FILL / BLEND colour (RGB444)
//   [125:122] alpha     BLEND strength in 1/16 (out = old*(16-a)/16 + color*a/16)
//   [126]     dither    draw only every other pixel (checkerboard) = 50% transparency
`timescale 1ns / 1ps
module line_engine #(
    parameter NOBJ = 176
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,          // pulse: render view line `vy`
    input  wire [8:0]   vy,             // 0..359
    input  wire         vmap_en,        // Stage 3: 352-line frame stretched to 360
    output reg  [7:0]   obj_idx,
    input  wire [127:0] obj_desc,       // combinational function of obj_idx (scene module)
    output wire         busy,
    // render line buffer
    output reg          lb_we,
    output reg  [9:0]   lb_waddr,
    output reg  [11:0]  lb_wdata,
    output wire [9:0]   lb_raddr,       // read port (1-cycle latency) for BLEND
    input  wire [11:0]  lb_rdata,
    // ROMs (2-cycle latency)
    output wire [13:0]  map_addr,  input wire [7:0]  map_q,
    output reg  [16:0]  p4_addr,   input wire [3:0]  p4_q,
    output reg  [17:0]  vqi_addr,  input wire [8:0]  vqi_q,
    output reg  [16:0]  cb_addr,   input wire [7:0]  cb_q,
    output reg  [12:0]  pal_addr,  input wire [11:0] pal_q
);
`include "asset_dir.vh"
`include "tile_dir.vh"
`include "vmap.vh"
`include "asset_ids.vh"

    localparam K_IMAGE = 3'd0, K_FILL = 3'd1, K_TILE = 3'd2, K_BLEND = 3'd3;

    // ------------------------------------------------------------------ object walk
    localparam S_IDLE = 4'd0, S_FETCH = 4'd1, S_LATCH = 4'd2, S_CHECK = 4'd3, S_SET1 = 4'd4,
               S_SET2 = 4'd5, S_SET3 = 4'd6, S_SET4 = 4'd7, S_DRAIN = 4'd8, S_RUN = 4'd9,
               S_NEXT = 4'd10, S_FLUSH = 4'd11;
    reg [3:0]  st;
    reg [8:0]  ly;                       // logical line (frame row)
    reg [127:0] d;
    reg [64:0] ad;                       // asset directory entry {vq, w, h, base, cbase, pbase}                       // asset directory entry {vq, w, h, base, cbase, pbase}
    reg [5:0]  drain_cnt;

    wire        d_en    = d[0];
    wire [2:0]  d_kind  = d[3:1];
    wire signed [10:0] d_x = d[14:4];
    wire signed [9:0]  d_y = d[24:15];
    wire [9:0]  d_w     = d[34:25];
    wire [8:0]  d_h     = d[43:35];
    wire signed [11:0] d_x_end = $signed({d_x[10], d_x}) + $signed({2'b00, d_w});
    wire [7:0]  d_asset = d[51:44];
    wire [18:0] d_sx0f  = d[70:52];
    wire [17:0] d_sy0f  = d[88:71];
    wire [9:0]  d_stepx = d[98:89];
    wire [9:0]  d_stepy = d[108:99];
    wire        d_flip  = d[109];
    wire [11:0] d_color = d[121:110];
    wire [3:0]  d_alpha = d[125:122];
    wire        d_dith  = d[126];

    wire        a_vq    = ad[64];
    wire [9:0]  a_w     = ad[63:54];
    wire [17:0] a_base  = ad[43:26];
    wire [12:0] a_cbase = ad[25:13];
    wire [12:0] a_pb    = ad[12:0];

    // per object-line values
    reg [9:0]  ry;                       // row inside the object
    reg [19:0] prod_y;
    reg [10:0] sy;                       // source row (integer)
    reg [10:0] x_start, x_end, dx;
    reg [10:0] offs;
    reg [20:0] prod_x;
    reg [19:0] acc;                      // source x, 11.8 fixed
    reg [17:0] line_base;
    reg [13:0] map_line;

    function [13:0] map_base;
        input [7:0] lvl;
        begin
            case (lvl)
                8'd1: map_base = MAP_BASE_1;
                8'd2: map_base = MAP_BASE_2;
                default: map_base = MAP_BASE_3;
            endcase
        end
    endfunction

    // pipeline input (stage A)
    reg        pa_v;
    reg [2:0]  pa_kind;
    reg [9:0]  pa_dx;
    reg [10:0] pa_sx;
    reg        pa_vq;
    reg [17:0] pa_base;
    reg [12:0] pa_cbase, pa_pbase;
    reg [1:0]  pa_sub_y;
    reg [4:0]  pa_tpy;
    reg [11:0] pa_color;
    reg [3:0]  pa_alpha;


    assign busy = (st != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; obj_idx <= 8'd0; pa_v <= 1'b0; d <= 128'd0; ad <= 65'd0; drain_cnt <= 6'd0;
        end else begin
            pa_v <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                    ly      <= vmap_en ? vmap(vy) : vy;
                    obj_idx <= 8'd0;
                    st      <= S_FETCH;
                end
                S_FETCH: st <= S_LATCH;            // obj_idx changed last cycle; descriptor settles
                S_LATCH: begin
                    d  <= obj_desc;
                    st <= S_CHECK;
                end
                S_CHECK: begin
                    ad <= asset_dir(d_asset);
                    if (!d_en || ($signed({2'b00, ly}) < $signed({{1{d_y[9]}}, d_y})) ||
                        ($signed({2'b00, ly}) >= $signed({{1{d_y[9]}}, d_y}) + $signed({2'b00, d_h}))) begin
                        if (obj_idx == NOBJ - 1) begin
                            drain_cnt <= 6'd16;
                            st <= S_FLUSH;
                        end else begin
                            obj_idx <= obj_idx + 8'd1;
                            st <= S_FETCH;
                        end
                    end else begin
                        ry <= ly - d_y[8:0];
                        st <= S_SET1;
                    end
                end
                S_SET1: begin
                    prod_y  <= ry * d_stepy;
                    x_start <= d_x[10] ? 11'd0 : d_x;
                    x_end   <= (d_x_end > 12'sd640) ? 11'd640 :
                               (d_x_end < 12'sd0)   ? 11'd0   : d_x_end[10:0];
                    st <= S_SET2;
                end
                S_SET2: begin
                    sy   <= (d_sy0f + prod_y[17:0]) >> 8;
                    offs <= d_flip ? (d_x + d_w - 11'd1 - x_start) : (x_start - d_x);
                    if (x_start >= x_end) st <= S_NEXT;
                    else if (d_kind == K_FILL) begin
                        dx <= x_start;
                        st <= S_RUN;
                    end else st <= S_SET3;
                end
                S_SET3: begin
                    prod_x <= offs * d_stepx;
                    // row base address of this object line
                    if (a_vq) line_base <= a_base + (sy[10:2] * a_w[9:2]);
                    else      line_base <= a_base + (sy * a_w);
                    map_line <= map_base(d_asset) + (sy[10:5] << 8) - (sy[10:5] << 2) - (sy[10:5] << 1)
                                + {6'd0, d_color[7:0]};   // TILEMAP: coarse scroll column (colour field)
                    st <= S_SET4;
                end
                S_SET4: begin
                    acc <= d_sx0f + prod_x[19:0];
                    dx  <= x_start;
                    if (d_kind == K_BLEND) begin
                        drain_cnt <= 6'd16;          // let earlier pixels reach the buffer first
                        st <= S_DRAIN;
                    end else st <= S_RUN;
                end
                S_DRAIN: begin
                    if (drain_cnt == 0) st <= S_RUN;
                    else drain_cnt <= drain_cnt - 6'd1;
                end
                S_RUN: begin
                    // one destination pixel per clock
                    pa_v     <= !d_dith || ((dx[0] ^ ly[0]) == 1'b0);
                    pa_kind  <= d_kind;
                    pa_dx    <= dx[9:0];
                    pa_sx    <= acc[18:8];
                    pa_vq    <= a_vq;
                    pa_base  <= (d_kind == K_TILE) ? {4'd0, map_line} : line_base;
                    pa_cbase <= a_cbase;
                    pa_pbase <= a_pb;
                    pa_sub_y <= sy[1:0];
                    pa_tpy   <= sy[4:0];
                    pa_color <= d_color;
                    pa_alpha <= d_alpha;
                    acc <= d_flip ? acc - d_stepx : acc + d_stepx;
                    if (dx + 11'd1 >= x_end) st <= S_NEXT;
                    dx <= dx + 11'd1;
                end
                S_NEXT: begin
                    if (obj_idx == NOBJ - 1) begin
                        drain_cnt <= 6'd16;
                        st <= S_FLUSH;
                    end else begin
                        obj_idx <= obj_idx + 8'd1;
                        st <= S_FETCH;
                    end
                end
                S_FLUSH: begin
                    if (drain_cnt == 0) st <= S_IDLE;
                    else drain_cnt <= drain_cnt - 6'd1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ pixel pipeline
    // Cycle numbers are relative to the cycle t in which the pixel sits in stage A (pa_*).
    //   t    : A  map_addr / lb_raddr presented
    //   t+1  : B  line-buffer read data valid (BLEND)
    //   t+2  : C  map_q valid -> tile directory -> P4 / VQ index address
    //   t+5  : F  p4_q / vqi_q valid -> code book address
    //   t+8  : I  cb_q valid -> palette address
    //   t+11 : L  pal_q valid -> line buffer write
    assign map_addr = pa_base[13:0] + {3'd0, pa_sx[10:5]};
    assign lb_raddr = pa_dx;

    // token carried down the pipe
    localparam TW = 1 + 3 + 10 + 1 + 13 + 13 + 12 + 12 + 4 + 4 + 1 + 4;   // = 78
    function [TW-1:0] pack;
        input v; input [2:0] kind; input [9:0] dxi; input vq; input [12:0] cbase, pbase;
        input [11:0] color, old; input [3:0] sub, alpha; input empty; input [3:0] p4;
        pack = {v, kind, dxi, vq, cbase, pbase, color, old, sub, alpha, empty, p4};
    endfunction
    `define T_V(t)     t[77]
    `define T_KIND(t)  t[76:74]
    `define T_DX(t)    t[73:64]
    `define T_VQ(t)    t[63]
    `define T_CBASE(t) t[62:50]
    `define T_PBASE(t) t[49:37]
    `define T_COLOR(t) t[36:25]
    `define T_OLD(t)   t[24:13]
    `define T_SUB(t)   t[12:9]
    `define T_ALPHA(t) t[8:5]
    `define T_EMPTY(t) t[4]
    `define T_P4(t)    t[3:0]

    reg        pb_v;  reg [2:0] pb_kind; reg [9:0] pb_dx; reg [10:0] pb_sx; reg pb_vq; reg [17:0] pb_base;
    reg [12:0] pb_cbase, pb_pbase; reg [11:0] pb_color; reg [1:0] pb_suby; reg [4:0] pb_tpy; reg [3:0] pb_alpha;
    reg        pc_v;  reg [2:0] pc_kind; reg [9:0] pc_dx; reg [10:0] pc_sx; reg pc_vq; reg [17:0] pc_base;
    reg [12:0] pc_cbase, pc_pbase; reg [11:0] pc_color, pc_old; reg [1:0] pc_suby; reg [4:0] pc_tpy; reg [3:0] pc_alpha;
    reg [TW-1:0] tD, tE, tF, tG, tH, tI, tJ, tK, tL;

    wire [45:0] td = tile_dir(map_q);

    // blend: old*(16-a)/16 + c*a/16 per channel
    function [3:0] lerp4;
        input [3:0] o, c, a;
        reg [8:0] s;
        begin
            s = o * (5'd16 - a) + c * a;
            lerp4 = s[7:4];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            pb_v <= 1'b0; pc_v <= 1'b0;
            tD <= 0; tE <= 0; tF <= 0; tG <= 0; tH <= 0; tI <= 0; tJ <= 0; tK <= 0; tL <= 0;
            lb_we <= 1'b0;
        end else begin
            // ---- B (t+1)
            pb_v <= pa_v; pb_kind <= pa_kind; pb_dx <= pa_dx; pb_sx <= pa_sx; pb_vq <= pa_vq; pb_base <= pa_base;
            pb_cbase <= pa_cbase; pb_pbase <= pa_pbase; pb_suby <= pa_sub_y; pb_tpy <= pa_tpy;
            pb_color <= pa_color; pb_alpha <= pa_alpha;
            // ---- C (t+2): capture the line-buffer read issued at t
            pc_v <= pb_v; pc_kind <= pb_kind; pc_dx <= pb_dx; pc_sx <= pb_sx; pc_vq <= pb_vq; pc_base <= pb_base;
            pc_cbase <= pb_cbase; pc_pbase <= pb_pbase; pc_suby <= pb_suby; pc_tpy <= pb_tpy;
            pc_color <= pb_color; pc_alpha <= pb_alpha; pc_old <= lb_rdata;
            // ---- D (t+3): map_q was valid during C -> choose the pixel source, present ROM addresses
            if (pc_kind == K_TILE) begin
              tD <= pack(pc_v, pc_kind, pc_dx, td[44], td[25:13], td[12:0], pc_color, pc_old,
                         {pc_tpy[1:0], pc_sx[1:0]}, pc_alpha, ~td[45], 4'd0);
              p4_addr  <= td[43:26] + {pc_tpy, pc_sx[4:0]};
              vqi_addr <= td[43:26] + {pc_tpy[4:2], pc_sx[4:2]};
            end else begin
                tD <= pack(pc_v, pc_kind, pc_dx, pc_vq, pc_cbase, pc_pbase, pc_color, pc_old,
                           {pc_suby, pc_sx[1:0]}, pc_alpha, 1'b0, 4'd0);
                p4_addr  <= pc_base + pc_sx;
                vqi_addr <= pc_base + pc_sx[10:2];
            end
            tE <= tD;
            // ---- F (t+5): ROM data valid during this cycle
            tF <= tE;
            // ---- G (t+6): code book address from vqi_q (valid during F), keep the P4 value
            cb_addr <= {(`T_CBASE(tF) + {4'd0, vqi_q}), `T_SUB(tF)};
            tG <= {tF[TW-1:4], p4_q};
            tH <= tG;
            tI <= tH;
            // ---- J (t+9): cb_q valid during I -> palette address
            pal_addr <= `T_PBASE(tI) + (`T_VQ(tI) ? {5'd0, cb_q} : {9'd0, `T_P4(tI)});
            tJ <= {tI[TW-1:5], `T_EMPTY(tI) | (`T_VQ(tI) ? (cb_q == 8'd0) : (`T_P4(tI) == 4'd0)), tI[3:0]};
            tK <= tJ;
            tL <= tK;
            // ---- M (t+12): pal_q valid during L -> write the line buffer
            lb_waddr <= `T_DX(tL);
            case (`T_KIND(tL))
                K_FILL:  begin lb_we <= `T_V(tL); lb_wdata <= `T_COLOR(tL); end
                K_BLEND: begin
                    lb_we <= `T_V(tL);
                    lb_wdata <= {lerp4(`T_OLD(tL) >> 8, `T_COLOR(tL) >> 8, `T_ALPHA(tL)),
                                 lerp4(`T_OLD(tL) >> 4, `T_COLOR(tL) >> 4, `T_ALPHA(tL)),
                                 lerp4(`T_OLD(tL),      `T_COLOR(tL),      `T_ALPHA(tL))};
                end
                default: begin lb_we <= `T_V(tL) & ~`T_EMPTY(tL); lb_wdata <= pal_q; end
            endcase
        end
    end
endmodule
