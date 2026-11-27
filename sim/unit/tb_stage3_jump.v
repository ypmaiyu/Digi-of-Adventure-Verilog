// tb_stage3_jump.v - Stage 3 physics against the Pygame numbers (settings.py):
//   single jump apex = JUMP_HEIGHT 2.5 tiles above the take-off, double jump apex = 4.5 tiles.
`timescale 1ns / 1ps
module tb_stage3_jump;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg start = 0, frame = 0; reg [4:0] lvl = 0, evp = 0; reg tap = 0, back = 0;
    wire done; wire [127:0] od; wire vmap; wire [95:0] pl; wire [7:0] fc; wire [15:0] fv; wire cv; wire [63:0] seg; wire [15:0] leds;
    stage3 dut (.clk(clk), .rst(rst), .active(1'b1), .start(start), .frame(frame), .lvl(lvl), .ev_press(evp), .ev_tap(tap),
                .ev_back(back), .hi_hearts(2'd3), .hi_form(2'd2), .dbg_win(1'b0), .dbg_jump(1'b0), .dbg_part(1'b0), .dbg_set_form(1'b0), .dbg_form(2'd2),
                .done(done), .obj_idx(6'd0), .obj_desc(od), .vmap_en(vmap),
                .prog_list(pl), .fld_id(8'd0), .fld_idx(7'd0), .fld_char(fc), .fld_val(fv), .cond_id(8'd0), .cond_val(cv),
                .seg_text(seg), .leds(leds));
    task tick; begin repeat (3000) @(posedge clk); @(posedge clk) frame <= 1; @(posedge clk) frame <= 0; end endtask
    integer i, err = 0;
    reg signed [31:0] ground, peak, take;
    real h1, h2;
    initial begin
        #100 rst = 0;
        @(posedge clk) start <= 1; @(posedge clk) start <= 0;
        for (i = 0; i < 60; i = i + 1) tick;                 // fall onto the ground
        if (!dut.grounded) begin err = err + 1; $display("player not on the ground after 1 s"); end
        ground = dut.py;
        // ---- single jump
        evp <= 5'b00001; tick; evp <= 0;
        peak = ground;
        for (i = 0; i < 70; i = i + 1) begin tick; if (dut.py > peak) peak = dut.py; end
        h1 = (peak - ground) / 65536.0;
        $display("single jump apex %0.3f tiles above the take-off (Pygame: 2.500)", h1);
        if (h1 < 2.45 || h1 > 2.55) err = err + 1;
        for (i = 0; i < 30; i = i + 1) tick;
        // ---- double jump: second press 0.3 s after the first
        take = dut.py;
        evp <= 5'b00001; tick; evp <= 0;
        for (i = 0; i < 18; i = i + 1) tick;
        evp <= 5'b00001; tick; evp <= 0;
        peak = take;
        for (i = 0; i < 90; i = i + 1) begin tick; if (dut.py > peak) peak = dut.py; end
        h2 = (peak - take) / 65536.0;
        $display("double jump apex %0.3f tiles above the take-off (Pygame: 4.500)", h2);
        if (h2 < 4.40 || h2 > 4.60) err = err + 1;
        if (err == 0) $display("PASS tb_stage3_jump"); else $display("FAIL tb_stage3_jump: %0d errors", err);
        $finish;
    end
endmodule
