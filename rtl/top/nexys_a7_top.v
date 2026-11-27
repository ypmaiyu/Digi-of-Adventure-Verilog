// nexys_a7_top.v - top level for the Digilent Nexys A7-100T (XC7A100T-1CSG324C).
// Port names = Digilent Nexys-A7-100T-Master.xdc (constraints/nexys_a7_100t.xdc).
//
//   CLK100MHZ -> MMCME2_BASE generates a single 74.25 MHz pixel/system clock (1280x720@60)
//   CPU_RESETN-> synchronised reset (held until MMCM locks)
//   BTNU/D/L/R/C, SW[15:0]  -> input_ctrl (synchroniser, debounce, one-shot, tap / hold)
//   VGA 12-bit colour, 1280x720 @ 60 Hz (2x scaled 640x360, native 16:9)
//   8-digit 7-segment display, 16 LEDs, 2 RGB LEDs (status, see docs/README)
`timescale 1ns / 1ps
module nexys_a7_top #(
    parameter DEBOUNCE = 742_500,           // 10 ms at 74.25 MHz; simulations use a small value
    parameter SIM_BYPASS_MMCM = 0
) (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        BTNC, BTNU, BTNL, BTNR, BTND,
    input  wire [15:0] SW,
    output wire [15:0] LED,
    output wire        LED16_R, LED16_G, LED16_B,
    output wire        LED17_R, LED17_G, LED17_B,
    output wire        CA, CB, CC, CD, CE, CF, CG, DP,
    output wire [7:0]  AN,
    output wire [3:0]  VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS
);
    // ---------------- 74.25 MHz clock from 100 MHz (100 * 37.125 / 5 / 10 = 74.250 MHz)
    wire clk, clk_fb, clk_74_unbuf, mmcm_locked;
    generate
        if (SIM_BYPASS_MMCM) begin : g_sim_clk
            assign clk = CLK100MHZ;
            assign mmcm_locked = 1'b1;
        end else begin : g_mmcm
            MMCME2_BASE #(
                .CLKIN1_PERIOD(10.0),
                .DIVCLK_DIVIDE(5),
                .CLKFBOUT_MULT_F(37.125),
                .CLKOUT0_DIVIDE_F(10.0),
                .STARTUP_WAIT("FALSE")
            ) u_mmcm (
                .CLKIN1(CLK100MHZ),
                .CLKFBIN(clk_fb),
                .CLKFBOUT(clk_fb),
                .CLKFBOUTB(),
                .CLKOUT0(clk_74_unbuf),
                .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
                .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
                .LOCKED(mmcm_locked),
                .PWRDWN(1'b0),
                .RST(!CPU_RESETN)
            );
            BUFG u_bufg (.I(clk_74_unbuf), .O(clk));
        end
    endgenerate

    // ---------------- reset: asynchronous assert, synchronous release ----------------
    reg [3:0] rst_ff = 4'hF;
    wire rst_src_n = CPU_RESETN && mmcm_locked;
    always @(posedge clk or negedge rst_src_n)
        if (!rst_src_n) rst_ff <= 4'hF;
        else            rst_ff <= {rst_ff[2:0], 1'b0};
    wire rst = rst_ff[3];

    // ---------------- inputs ----------------
    wire [4:0]  lvl, ev_press, btn_now;
    wire        ev_tap, ev_back;
    wire [15:0] sw, sw_rise, sw_fall, sw_now;
    wire        frame_tick, vblank;
    input_ctrl #(.DEBOUNCE(DEBOUNCE)) u_in (.clk(clk), .rst(rst), .frame_tick(frame_tick), .btn_raw({BTNC, BTNR, BTNL, BTND, BTNU}),
                     .sw_raw(SW), .lvl(lvl), .ev_press(ev_press), .ev_tap(ev_tap), .ev_back(ev_back),
                     .sw(sw), .sw_rise(sw_rise), .sw_fall(sw_fall), .btn_now(btn_now), .sw_now(sw_now));

    // ---------------- video ----------------
    wire [7:0]   obj_idx;  wire [127:0] obj_desc; wire vmap_en;
    wire [95:0]  prog_list;
    wire [7:0]   fld_id, cond_id, fld_char; wire [6:0] fld_idx; wire [15:0] fld_val; wire cond_val;
    video_core u_video (.clk(clk), .rst(rst), .frame_tick(frame_tick), .vblank(vblank),
                        .obj_idx(obj_idx), .obj_desc(obj_desc), .vmap_en(vmap_en), .prog_list(prog_list),
                        .fld_id(fld_id), .fld_idx(fld_idx), .fld_char(fld_char), .fld_val(fld_val),
                        .cond_id(cond_id), .cond_val(cond_val),
                        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B), .vga_hs(VGA_HS), .vga_vs(VGA_VS));

    // ---------------- game ----------------
    wire [63:0] seg_text;
    wire [2:0]  rgb16, rgb17, scene;
    game_flow u_game (.clk(clk), .rst(rst), .frame(frame_tick), .lvl(lvl), .ev_press(ev_press), .ev_tap(ev_tap),
                      .ev_back(ev_back), .sw(sw), .sw_rise(sw_rise), .sw_fall(sw_fall), .sw_now(sw_now),
                      .obj_idx(obj_idx), .obj_desc(obj_desc), .vmap_en(vmap_en), .prog_list(prog_list),
                      .fld_id(fld_id), .fld_idx(fld_idx), .fld_char(fld_char), .fld_val(fld_val),
                      .cond_id(cond_id), .cond_val(cond_val), .seg_text(seg_text), .leds(LED),
                      .rgb16(rgb16), .rgb17(rgb17), .scene(scene));
    assign {LED16_R, LED16_G, LED16_B} = rgb16;
    assign {LED17_R, LED17_G, LED17_B} = rgb17;

    // ---------------- 7-segment ----------------
    wire [6:0] seg;
    seg7_ctrl u_seg (.clk(clk), .rst(rst), .text(seg_text), .an(AN), .seg(seg), .dp(DP));
    assign {CG, CF, CE, CD, CC, CB, CA} = seg;
endmodule
