// video_core.v - everything between the game logic and the VGA connector.
//
//   vga_timing  : 1280x720@60 counters on the 74.25 MHz clock
//   line_engine : paints each logical line (0..359) into a double line buffer (2x scaled vertically)
//   line buffers: two 1024x12 RAMs (one being shown for 2 scanlines, one being painted)
//   ui_painter  : repaints the 80x45 text layer every vertical blank (2x scaled -> 1280x720)
//   text layer  : text RAM (80x45 = 3600 cells) + 8x8 font ROM, drawn on top of everything
//   asset_roms  : sprite / picture ROMs
`timescale 1ns / 1ps
module video_core (
    input  wire         clk,
    input  wire         rst,
    // timing out
    output wire         frame_tick,
    output wire         vblank,
    // object list of the active scene
    output wire [7:0]   obj_idx,
    input  wire [127:0] obj_desc,
    input  wire         vmap_en,
    // UI painter ports
    input  wire [95:0]  prog_list,
    output wire [7:0]   fld_id,
    output wire [6:0]   fld_idx,
    input  wire [7:0]   fld_char,
    input  wire [15:0]  fld_val,
    output wire [7:0]   cond_id,
    input  wire         cond_val,
    // VGA
    output reg  [3:0]   vga_r,
    output reg  [3:0]   vga_g,
    output reg  [3:0]   vga_b,
    output reg          vga_hs,
    output reg          vga_vs
);
`include "ui_pal.vh"

    wire        pix_ce, active, hs_n, vs_n, line_start;
    wire [10:0] hc;
    wire [9:0]  vc;
    vga_timing u_tim (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hc(hc), .vc(vc),
                      .active(active), .hsync_n(hs_n), .vsync_n(vs_n), .vblank(vblank),
                      .line_start(line_start), .frame_tick(frame_tick));

    // ---------------------------------------------------------------- line buffers (2x scale)
    // Flip buf_sel at the start of every EVEN visible line (0, 2, 4, ..., 718) so each
    // logical row vy (0..359) stays in the display buffer for 2 full 720p scanlines (3300 clocks).
    reg  buf_sel;
    wire end_of_line = (hc == 11'd1649);
    always @(posedge clk) begin
        if (rst) buf_sel <= 1'b0;
        else if (end_of_line && (vc == 10'd749 || (vc[0] == 1'b1 && vc < 10'd719)))
            buf_sel <= ~buf_sel;
    end

    wire        e_we;   wire [9:0] e_waddr;  wire [11:0] e_wdata;
    wire [9:0]  e_raddr; reg [11:0] e_rdata;
    reg  [11:0] lb0 [0:1023];
    reg  [11:0] lb1 [0:1023];
    reg  [11:0] lb0_q, lb1_q;
    // port A: engine writes into the render buffer
    always @(posedge clk) if (e_we &&  buf_sel) lb0[e_waddr] <= e_wdata;
    always @(posedge clk) if (e_we && !buf_sel) lb1[e_waddr] <= e_wdata;
    // port B: display read + clear-after-read on odd scanline (2nd pass of the logical row)
    wire [9:0] v_addr = hc[10:1];
    wire       v_clr  = (vc < 10'd720) && vc[0] && (hc < 11'd1280) && hc[0];
    wire [9:0] b0_addr = buf_sel ? e_raddr : v_addr;
    wire [9:0] b1_addr = buf_sel ? v_addr  : e_raddr;
    always @(posedge clk) begin
        if (!buf_sel && v_clr) lb0[b0_addr] <= 12'h000;
        lb0_q <= lb0[b0_addr];
    end
    always @(posedge clk) begin
        if (buf_sel && v_clr) lb1[b1_addr] <= 12'h000;
        lb1_q <= lb1[b1_addr];
    end
    always @(*) e_rdata = buf_sel ? lb0_q : lb1_q;
    wire [11:0] v_pix = buf_sel ? lb1_q : lb0_q;

    // ---------------------------------------------------------------- line engine
    // Start painting vy=0 on vc=748, vy=1 on vc=0, ..., vy=359 on vc=716 (3300 clocks per row).
    reg        eng_start; reg [8:0] eng_vy;
    always @(posedge clk) begin
        eng_start <= 1'b0;
        if (end_of_line && (vc == 10'd747 || vc == 10'd749 || (vc[0] == 1'b1 && vc < 10'd717))) begin
            eng_start <= 1'b1;
            eng_vy    <= (vc == 10'd747) ? 9'd0 : (vc == 10'd749) ? 9'd1 : (vc[9:1] + 9'd2);
        end
    end

    wire [13:0] map_addr; wire [7:0] map_q;
    wire [16:0] p4_addr;  wire [3:0] p4_q;
    wire [17:0] vqi_addr; wire [8:0] vqi_q;
    wire [16:0] cb_addr;  wire [7:0] cb_q;
    wire [12:0] pal_addr; wire [11:0] pal_q;
    wire        eng_busy;

    line_engine u_eng (
        .clk(clk), .rst(rst), .start(eng_start), .vy(eng_vy), .vmap_en(vmap_en),
        .obj_idx(obj_idx), .obj_desc(obj_desc), .busy(eng_busy),
        .lb_we(e_we), .lb_waddr(e_waddr), .lb_wdata(e_wdata), .lb_raddr(e_raddr), .lb_rdata(e_rdata),
        .map_addr(map_addr), .map_q(map_q), .p4_addr(p4_addr), .p4_q(p4_q),
        .vqi_addr(vqi_addr), .vqi_q(vqi_q), .cb_addr(cb_addr), .cb_q(cb_q), .pal_addr(pal_addr), .pal_q(pal_q));

    asset_roms u_roms (
        .clk(clk), .p4_addr(p4_addr), .p4_q(p4_q), .vqi_addr(vqi_addr), .vqi_q(vqi_q),
        .cb_addr(cb_addr), .cb_q(cb_q), .pal_addr(pal_addr), .pal_q(pal_q), .map_addr(map_addr), .map_q(map_q));

    // ---------------------------------------------------------------- text layer (80x45 -> 1280x720)
    wire [12:0] t_addr; wire t_we; wire [19:0] t_wdata; reg [19:0] t_rdata;
    wire        painter_busy;
    ui_painter u_paint (
        .clk(clk), .rst(rst), .start(frame_tick), .prog_list(prog_list),
        .fld_id(fld_id), .fld_idx(fld_idx), .fld_char(fld_char), .fld_val(fld_val),
        .cond_id(cond_id), .cond_val(cond_val),
        .t_addr(t_addr), .t_we(t_we), .t_wdata(t_wdata), .t_rdata(t_rdata), .busy(painter_busy));

    reg [19:0] tram [0:3599];
    integer ti;
    initial for (ti = 0; ti < 3600; ti = ti + 1) tram[ti] = 20'd0;
    always @(posedge clk) begin                       // port A: painter
        if (t_we) tram[t_addr] <= t_wdata;
        t_rdata <= tram[t_addr];
    end
    reg [19:0] cell_q;
    wire [12:0] v_cell = {vc[9:4], 6'd0} + {2'd0, vc[9:4], 4'd0} + {6'd0, hc[10:4]};
    always @(posedge clk) cell_q <= tram[v_cell];     // port B: display

    (* rom_style = "block" *) reg [7:0] font [0:1023];
    initial $readmemh("font.mem", font);
    reg [9:0] f_addr; reg [7:0] f_q;
    always @(posedge clk) f_q <= font[f_addr];

    // ---------------------------------------------------------------- 3-stage pixel output pipeline (74.25 MHz)
    // Cycle 0 (hc, vc): tram[v_cell] and lb[hc[10:1]] read
    // Cycle 1 (hc1):    cell_q and v_pix valid -> font[f_addr] read; latch base_px on even pixel
    // Cycle 2 (hc2):    f_q valid -> blend UI over base_px2 into VGA output register
    reg [10:0] hc1; reg [9:0] vc1; reg act1, hs1, vs1, act2, hs2, vs2, act3, hs3, vs3;
    reg [11:0] base_px1, base_px2;
    reg [19:0] cell_r1, cell_r2;
    reg [2:0]  fx1, fx2;
    wire [4:0]  c_fg = cell_r2[12:8];
    wire [4:0]  c_bg = cell_r2[7:3];
    wire        on   = f_q[3'd7 - fx2];
    wire [11:0] px   = on ? ui_pal(c_fg) : (c_bg != 5'd0) ? ui_pal(c_bg) : base_px2;
    always @(posedge clk) begin
        if (rst) begin
            hc1 <= 0; vc1 <= 0; act1 <= 0; hs1 <= 0; vs1 <= 0;
            act2 <= 0; hs2 <= 0; vs2 <= 0; act3 <= 0; hs3 <= 0; vs3 <= 0;
            base_px1 <= 0; base_px2 <= 0; cell_r1 <= 0; cell_r2 <= 0; fx1 <= 0; fx2 <= 0;
            f_addr <= 0;
            vga_r <= 4'd0; vga_g <= 4'd0; vga_b <= 4'd0; vga_hs <= 1'b0; vga_vs <= 1'b0;
        end else begin
            // Stage 1 (reads BRAM at Cycle 0)
            hc1 <= hc; vc1 <= vc; act1 <= active; hs1 <= hs_n; vs1 <= vs_n;
            // Stage 2 (consumes cell_q & v_pix, reads font BRAM)
            act2     <= act1; hs2 <= hs1; vs2 <= vs1;
            cell_r1  <= cell_q;
            if (!hc1[0]) base_px1 <= v_pix;
            f_addr   <= {cell_q[19:13], cell_q[2] ? {cell_q[0], vc1[3:2]} : vc1[3:1]};
            fx1      <= cell_q[2] ? {cell_q[1], hc1[3:2]} : hc1[3:1];
            // Stage 3 (f_q valid on posedge -> latch Stage 2 data aligned with act3)
            act3     <= act2; hs3 <= hs2; vs3 <= vs2;
            cell_r2  <= cell_r1;
            base_px2 <= base_px1;
            fx2      <= fx1;

            {vga_r, vga_g, vga_b} <= act3 ? px : 12'h000;
            vga_hs <= hs3;
            vga_vs <= vs3;
        end
    end
endmodule

