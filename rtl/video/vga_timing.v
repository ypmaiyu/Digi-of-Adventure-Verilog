// vga_timing.v - 1280x720 @ 60 Hz (CEA-861 720p60) timing on the 74.25 MHz pixel clock.
//
//   horizontal: 1280 visible +  86 front porch + 40 sync (+) + 244 back porch = 1650 pixels
//   vertical  :  720 visible +   2 front porch +  5 sync (+) +  23 back porch =  750 lines
// line_start : 1-cycle pulse at the first cycle of every line (hc = 0)
// frame_tick : 1-cycle pulse at the start of the vertical blank (vc = 720) -> game logic update
`timescale 1ns / 1ps
module vga_timing (
    input  wire        clk,
    input  wire        rst,
    output wire        pix_ce,      // 1'b1 every 74.25 MHz clock
    output reg  [10:0] hc /*verilator public_flat_rd*/,     // 0..1649
    output reg  [9:0]  vc /*verilator public_flat_rd*/,     // 0..749
    output wire        active,      // inside the 1280x720 picture
    output wire        hsync_n,     // positive sync polarity for 720p60 (kept port name for compatibility)
    output wire        vsync_n,
    output wire        vblank,      // vc >= 720
    output reg         line_start,
    output reg         frame_tick
);
    assign pix_ce  = 1'b1;
    assign active  = (hc < 11'd1280) && (vc < 10'd720);
    assign hsync_n = (hc >= 11'd1366) && (hc < 11'd1406);   // +40 px sync pulse (HBP 244)
    assign vsync_n = (vc >= 10'd722) && (vc < 10'd727);     // +5 line sync pulse (VBP 23)
    assign vblank  = (vc >= 10'd720);

    always @(posedge clk) begin
        if (rst) begin
            hc <= 11'd0; vc <= 10'd0;
            line_start <= 1'b0; frame_tick <= 1'b0;
        end else begin
            line_start <= 1'b0;
            frame_tick <= 1'b0;
            if (hc == 11'd1649) begin
                hc <= 11'd0;
                line_start <= 1'b1;
                if (vc == 10'd749) vc <= 10'd0;
                else               vc <= vc + 10'd1;
                if (vc == 10'd719) frame_tick <= 1'b1;
            end else begin
                hc <= hc + 11'd1;
            end
        end
    end
endmodule
