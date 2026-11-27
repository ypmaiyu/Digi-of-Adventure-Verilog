// tb_vga_timing.v - 1280x720 @ 60 Hz: 1650 x 750 pixel slots, sync widths, one frame_tick per frame
`timescale 1ns / 1ps
module tb_vga_timing;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    wire pix_ce, active, hs, vs, vblank, line_start, frame_tick;
    wire [10:0] hc; wire [9:0] vc;
    vga_timing dut (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hc(hc), .vc(vc), .active(active),
                    .hsync_n(hs), .vsync_n(vs), .vblank(vblank), .line_start(line_start), .frame_tick(frame_tick));
    integer ce = 0, act = 0, hsl = 0, frames = 0, cyc = 0, t0 = 0, period = 0, vsl = 0, err = 0;
    always @(posedge clk) if (!rst) begin
        cyc = cyc + 1;
        if (pix_ce) begin
            ce = ce + 1;
            if (active) act = act + 1;
            if (hs) hsl = hsl + 1;
            if (vs) vsl = vsl + 1;
        end
        if (frame_tick) begin
            frames = frames + 1;
            if (frames == 2) begin t0 = cyc; ce = 0; act = 0; hsl = 0; vsl = 0; end
            if (frames == 3) period = cyc - t0;
        end
    end
    initial begin
        #100 rst = 0;
        wait (frames == 3);
        if (period != 1650 * 750) begin err = err + 1; $display("frame period %0d cycles, expected %0d", period, 1650 * 750); end
        if (ce != 1650 * 750) begin err = err + 1; $display("pixel slots %0d", ce); end
        if (act != 1280 * 720) begin err = err + 1; $display("active pixels %0d", act); end
        if (hsl != 40 * 750) begin err = err + 1; $display("hsync high slots %0d, expected %0d", hsl, 40 * 750); end
        if (vsl != 5 * 1650) begin err = err + 1; $display("vsync high slots %0d, expected %0d", vsl, 5 * 1650); end
        if (err == 0) $display("PASS tb_vga_timing (1650x750 slots, 1280x720 active, hsync +40, vsync +5 lines)");
        else $display("FAIL tb_vga_timing: %0d errors", err);
        $finish;
    end
endmodule
